package dev.reticle.cli

import dev.reticle.cli.platform.DeviceController
import dev.reticle.cli.platform.android.Adb
import dev.reticle.cli.platform.android.Injector
import dev.reticle.cli.platform.android.InputBackend
import dev.reticle.core.CompactObservation
import dev.reticle.core.MutationRequest
import dev.reticle.core.ReticleJson
import dev.reticle.core.SemanticTree
import dev.reticle.core.Snapshot
import java.io.File
import java.util.Base64
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** Device/runtime-backed helper RPC commands. */
internal object HelperDeviceCommands {

    fun listDevices(): JsonElement {
        val states = Adb.forSerial(null).listDeviceStates()
        return buildJsonObject {
            put("devices", buildJsonArray {
                states.forEach { s ->
                    add(buildJsonObject {
                        put("serial", s.serial)
                        put("state", s.state)
                    })
                }
            })
        }
    }

    fun status(params: JsonObject): JsonElement {
        val pkg = params.str("package")
        val device = Adb.forSerial(params.str("serial"))
        val states = device.listDeviceStates()
        return buildJsonObject {
            put("devices", buildJsonArray {
                states.forEach { s -> add(buildJsonObject { put("serial", s.serial); put("state", s.state) }) }
            })
            if (pkg != null) {
                device.ensureDeviceReady()
                val pid = device.pidOf(pkg)
                put("package", pkg)
                put("running", pid != null)
                if (pid != null) put("pid", pid)
                val client = runtimeClientFor(device, pkg, params)
                put("runtime", when (val h = client.probe()) {
                    is RuntimeHealth.Healthy ->
                        if (h.info.packageName == pkg && RuntimeIdentity.mismatch(device, client.hostPort, h.info) == null) {
                            "healthy"
                        } else {
                            "conflict"
                        }
                    is RuntimeHealth.Unreachable -> "unreachable"
                    is RuntimeHealth.Unresponsive -> "unresponsive"
                    is RuntimeHealth.Foreign -> "foreign"
                })
            }
        }
    }

    fun inject(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("inject needs 'package'")
        params.str("payloadDex")?.let { System.setProperty("reticle.payloadDex", it) }
        val device = Adb.forSerial(params.str("serial"))
        device.ensureDeviceReady()
        val injected = Injector.inject(device, pkg, restartUnderDebugger = params.bool("restartUnderDebugger"))
        val info = awaitRuntime(runtimeClientFor(device, pkg, params), pkg)
        return buildJsonObject {
            put("pid", info.pid)
            put("packageName", info.packageName)
            put("port", info.port)
            put("agentVersion", info.agentVersion)
            put("reportedPort", injected.reportedPort)
        }
    }

    fun uiReport(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("uiReport needs 'package'")
        val device = Adb.forSerial(params.str("serial"))
        device.ensureDeviceReady()
        val client = runtimeClientFor(device, pkg, params)
        assertHealthy(client, pkg)
        val report = client.report()
        return reportJson(report.snapshot, report.semantics, report.compact)
    }

    /**
     * One raw `/snapshot`, for the host's own polling loops (`act wait`). Forwarded
     * as parsed JSON, never decoded into [Snapshot]: the host decodes it, so a field
     * the Kotlin model lacks still reaches it. `probe=false` skips the `/runtime`
     * health + pid check — a loop probes on its first fetch only.
     */
    fun snapshot(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("snapshot needs 'package'")
        val device = Adb.forSerial(params.str("serial"))
        device.ensureDeviceReady()
        val client = runtimeClientFor(device, pkg, params)
        if (params["probe"] == null || params.bool("probe")) assertHealthy(client, pkg)
        val snapshot = ReticleJson.instance.parseToJsonElement(client.snapshotJson())
        val screenshotPath = params.str("screenshotPath")
        return buildJsonObject {
            put("snapshot", snapshot)
            // A trace side: the picture goes to a FILE the host named (same machine),
            // never base64 down the pipe. Best effort, like the trace it serves — a
            // picture that cannot be taken is `false`, not a failed snapshot.
            if (screenshotPath != null) {
                val wrote = runCatching { File(screenshotPath).writeBytes(client.screenshotBytes()) }.isSuccess
                put("screenshot", wrote)
            }
        }
    }

    /**
     * One `adb shell input` dispatch, for the host's own gesture orchestration. The
     * helper decides nothing here: no resolution, no settle, no evidence — those are
     * the host's. Only the device-I/O details stay (the shell escaping of `text`).
     */
    fun input(params: JsonObject): JsonElement {
        val kind = params.str("kind") ?: throw CliError("input needs 'kind'")
        val device = Adb.forSerial(params.str("serial"))
        device.ensureDeviceReady()
        val input = InputBackend(device)
        fun point(key: String) = parseXY(params.str(key) ?: throw CliError("input $kind needs '$key'"))
        val r = when (kind) {
            "tap" -> input.tap(
                params.intOrNull("x") ?: throw CliError("input tap needs 'x'"),
                params.intOrNull("y") ?: throw CliError("input tap needs 'y'"),
            )
            "swipe", "drag" -> {
                val (fx, fy) = point("from")
                val (tx, ty) = point("to")
                val dur = params.intOrNull("durationMs") ?: if (kind == "drag") 1000 else 300
                if (kind == "drag") input.drag(fx, fy, tx, ty, dur) else input.swipe(fx, fy, tx, ty, dur)
            }
            "text" -> input.text(
                params.str("text") ?: throw CliError("input text needs 'text'"),
                params.intOrNull("perCharDelayMs") ?: 0,
            )
            "keyevent" -> {
                val keys = (params["keys"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                if (keys.isNullOrEmpty()) throw CliError("input keyevent needs 'keys'")
                input.keyevent(*keys.toTypedArray())
            }
            "paste" -> input.paste()
            else -> throw CliError("unknown input kind '$kind' (tap/swipe/drag/text/keyevent/paste)")
        }
        return buildJsonObject {
            put("ok", r.ok)
            if (!r.ok && r.stderr.isNotBlank()) put("stderr", r.stderr)
        }
    }

    /**
     * The Toast Queue watch, split across two calls so the host can wrap any action
     * in it. `start` returns a token; `stop` returns what was seen. The sampling
     * thread and the dumpsys parsing stay here — they read device text, not a
     * snapshot. See [ToastWatches] for why a token is reaped on its own.
     */
    fun toastWatch(params: JsonObject): JsonElement = when (val op = params.str("op")) {
        "start" -> {
            val pkg = params.str("package") ?: throw CliError("toastWatch start needs 'package'")
            val device = Adb.forSerial(params.str("serial"))
            device.ensureDeviceReady()
            buildJsonObject { put("token", ToastWatches.start(device, pkg)) }
        }
        "stop" -> {
            val token = params.str("token") ?: throw CliError("toastWatch stop needs 'token'")
            buildJsonObject {
                put("toasts", buildJsonArray {
                    ToastWatches.stop(token).forEach { t ->
                        add(buildJsonObject {
                            put("summary", ToastQueue.summary(t))
                            put("kind", t.kind)
                            t.duration?.let { put("duration", it) }
                        })
                    }
                })
            }
        }
        else -> throw CliError("toastWatch needs 'op': start or stop (got '$op')")
    }

    /**
     * Dismiss the system keyboard. Preferred path is the in-app agent's
     * InputMethodManager (deterministic, reports settled before/after state);
     * when the agent is unreachable we fall back to KEYCODE_ESCAPE — unlike
     * KEYCODE_BACK it does not navigate back when the keyboard is already gone.
     * The fallback is Android-specific device I/O, which is why this stays a
     * helper call rather than a host-side composition of two primitives.
     */
    fun hideKeyboard(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("hideKeyboard needs 'package'")
        val device = Adb.forSerial(params.str("serial"))
        device.ensureDeviceReady()
        val client = runtimeClientFor(device, pkg, params)
        if (client.probe() is RuntimeHealth.Healthy) {
            val result = client.hideKeyboard()
            return buildJsonObject {
                put("gesture", "hideKeyboard")
                put("via", "agent imm")
                put("wasVisible", result.wasVisible)
                put("keyboardVisible", result.keyboard.visible)
            }
        }
        val r = InputBackend(device).keyevent("KEYCODE_ESCAPE")
        if (!r.ok) {
            throw CliError("agent unreachable and keyevent fallback failed: ${r.stderr.ifBlank { "adb shell did not complete" }}")
        }
        return buildJsonObject {
            put("gesture", "hideKeyboard")
            put("via", "keyevent ESCAPE (agent unreachable; state unknown)")
        }
    }

    fun launch(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("launch needs 'package'")
        val device = Adb.forSerial(params.str("serial"))
        device.ensureDeviceReady()
        var r = device.shell("monkey -p $pkg -c android.intent.category.LAUNCHER 1")
        if (!r.ok) {
            Thread.sleep(500)
            r = device.shell("monkey -p $pkg -c android.intent.category.LAUNCHER 1")
        }
        if (!r.ok) throw CliError("failed to launch $pkg: ${r.stderr.ifBlank { "adb shell did not complete" }}")
        val info = awaitRuntime(runtimeClientFor(device, pkg, params), pkg)
        return buildJsonObject {
            put("pid", info.pid)
            put("packageName", info.packageName)
            put("port", info.port)
            put("agentVersion", info.agentVersion)
        }
    }

    /**
     * The gestures that still run in the helper: `scroll-to`, `wheel` and `type`.
     * Everything else — tap, swipe, drag, hide-keyboard, wait — is orchestrated by
     * the host over `snapshot` / `input` / `hideKeyboard`, and so is the envelope
     * around EVERY gesture (`--verify`, the trace, the Toast Queue watch): the host
     * wraps these three too, so this returns the bare gesture result.
     */
    fun act(params: JsonObject): JsonElement {
        val sub = params.str("gesture") ?: throw CliError("act needs 'gesture'")
        val pkg = params.str("package") ?: throw CliError("act needs 'package'")
        val device = Adb.forSerial(params.str("serial"))
        device.ensureDeviceReady()
        val input = InputBackend(device)
        return when (sub) {
            "scrollTo", "scroll-to" -> HelperScrollTo.run(input, device, pkg, params)
            "wheel" -> HelperWheel.run(input, device, pkg, params)
            "type" -> HelperTypeText.typeText(input, device, pkg, params)
            else -> throw CliError(
                "unknown act gesture '$sub' (the helper runs scroll-to/wheel/type; " +
                    "tap/swipe/drag/hide-keyboard/wait run in the host)"
            )
        }
    }

    fun mutate(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("mutate needs 'package'")
        val property = params.str("property") ?: throw CliError("mutate needs 'property'")
        val rawValue = params.str("value") ?: throw CliError("mutate needs 'value'")
        val device = Adb.forSerial(params.str("serial"))
        device.ensureDeviceReady()
        val client = runtimeClientFor(device, pkg, params)
        assertHealthy(client, pkg)
        val result = client.mutate(MutationRequest(selectorFrom(params), property, parseValue(rawValue)))
        if (!result.applied) throw CliError(result.message ?: "mutation failed")
        return buildJsonObject {
            put("applied", true)
            put("ref", result.ref)
            put("previousValue", result.previousValue?.displayString())
        }
    }

    fun logs(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("logs needs 'package'")
        val device = Adb.forSerial(params.str("serial"))
        device.ensureDeviceReady()
        val client = runtimeClientFor(device, pkg, params)
        assertHealthy(client, pkg)
        return buildJsonObject {
            put("entries", buildJsonArray {
                client.logs().entries.forEach { e ->
                    add(buildJsonObject { put("level", e.level); put("message", e.message) })
                }
            })
        }
    }

    fun logcat(params: JsonObject): JsonElement {
        val lines = Adb.forSerial(params.str("serial")).agentLog()
        return buildJsonObject {
            put("lines", buildJsonArray { lines.forEach { add(it) } })
        }
    }

    fun screenshot(params: JsonObject): JsonElement {
        val pkg = params.str("package")
        val device = Adb.forSerial(params.str("serial"))
        device.ensureDeviceReady()
        var via = "adb screencap"
        // One client and one probe serve both the capture attempt and the
        // degrade notes below; building a second client for the notes used to
        // pay a second `adb forward` fork and a second probe in the same RPC.
        val client = pkg?.let { runtimeClientFor(device, it, params) }
        val agentUp = client != null && client.probe() is RuntimeHealth.Healthy
        val agentBytes = if (agentUp) {
            captureAgentScreenshot(client!!)?.also { via = "agent /screenshot" }
        } else {
            null
        }
        val bytes = agentBytes ?: device.screencap().also {
            if (it.isEmpty()) throw CliError("screencap returned no data (device ready?)")
        }
        return buildJsonObject {
            put("via", via)
            put("pngBase64", Base64.getEncoder().encodeToString(bytes))
            val degraded = if (agentUp) screenshotDegrades(client!!, viaAgent = agentBytes != null) else null
            if (!degraded.isNullOrEmpty()) {
                put("degraded", buildJsonArray { degraded.forEach { add(it) } })
            }
        }
    }

    /**
     * What this picture is missing, said out loud. A blank rect in a screenshot is
     * indistinguishable from "the app drew nothing there", so each capture path
     * reports its own blindness from the nodes the agent already marks:
     *
     * - in-process: `pixels:unavailable` nodes (a `SurfaceView`'s own surface is
     *   composited by SurfaceFlinger, so the Canvas walk leaves a transparent hole);
     * - device-level `screencap`: `screencap:blank` windows (`FLAG_SECURE` blanks the
     *   whole frame, while the in-process capture is unaffected).
     *
     * Best-effort: a snapshot that cannot be fetched simply yields no note, since the
     * picture itself is already written.
     *
     * [client] is the client [screenshot] already built and probed healthy —
     * reused so the notes cost one snapshot fetch, not a second forward + probe.
     */
    private fun screenshotDegrades(
        client: RuntimeClient,
        viaAgent: Boolean,
    ): List<String> = runCatching {
        val snapshot = client.snapshot()
        val out = ArrayList<String>()
        for (node in snapshot.nodes.values) {
            if (viaAgent && node.pixelsUnavailable()) {
                val id = node.testId ?: node.resourceId ?: node.ref
                val where = node.frame?.let {
                    " [${it.x.toInt()},${it.y.toInt()} ${it.width.toInt()}x${it.height.toInt()}]"
                } ?: ""
                out += "$id$where is not in this picture: an in-process capture cannot read " +
                    "another process's surface (${node.typeName}). `adb exec-out screencap` can."
            }
            if (node.screencapBlank()) {
                out += if (viaAgent) {
                    "${node.ref} is a FLAG_SECURE window: this in-process picture is complete, but a " +
                        "device-level `adb exec-out screencap` of it comes back blank."
                } else {
                    "${node.ref} is a FLAG_SECURE window: THIS picture is blanked by the system. " +
                        "The in-process capture (`--package`, with the agent up) is unaffected."
                }
            }
        }
        out
    }.getOrElse { emptyList() }

    /** A fresh snapshot, or null when the runtime cannot answer for one. */
    fun liveSnapshot(device: DeviceController, pkg: String, params: JsonObject): Snapshot? =
        runCatching {
            val client = runtimeClientFor(device, pkg, params)
            if (client.probe() is RuntimeHealth.Healthy) client.snapshot() else null
        }.getOrNull()

    private fun reportJson(snapshot: Snapshot, semantic: SemanticTree, compact: CompactObservation): JsonElement =
        buildJsonObject {
            put("nodeCount", snapshot.nodes.size)
            put("compactItemCount", compact.items.size)
            put("semanticNodeCount", semantic.nodes.size)
            put("snapshot", ReticleJson.compact.encodeToJsonElement(Snapshot.serializer(), snapshot))
            put("semantics", ReticleJson.compact.encodeToJsonElement(SemanticTree.serializer(), semantic))
            put("compact", ReticleJson.compact.encodeToJsonElement(CompactObservation.serializer(), compact))
        }

    private fun captureAgentScreenshot(client: RuntimeClient): ByteArray? =
        // The client already returns PNG bytes; no need to round-trip through a
        // temp file (write + read back) as this used to.
        runCatching { client.screenshotBytes() }.getOrNull()
}
