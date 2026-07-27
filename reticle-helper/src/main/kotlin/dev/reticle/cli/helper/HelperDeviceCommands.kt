package dev.reticle.cli

import dev.reticle.cli.platform.DeviceController
import dev.reticle.cli.platform.InputDispatcher
import dev.reticle.cli.platform.android.Adb
import dev.reticle.cli.platform.android.Injector
import dev.reticle.cli.platform.android.InputBackend
import dev.reticle.core.CompactObservation
import dev.reticle.core.MutationRequest
import dev.reticle.core.ReticleJson
import dev.reticle.core.SemanticTree
import dev.reticle.core.Snapshot
import java.util.Base64
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
                    is RuntimeHealth.Healthy -> if (h.info.packageName == pkg) "healthy" else "conflict"
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
        val injected = Injector.inject(device, pkg)
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

    fun act(params: JsonObject): JsonElement {
        val sub = params.str("gesture") ?: throw CliError("act needs 'gesture'")
        val pkg = params.str("package") ?: throw CliError("act needs 'package'")
        val device = Adb.forSerial(params.str("serial"))
        device.ensureDeviceReady()
        val input = InputBackend(device)

        val verifySel = HelperVerify.watchSelectorFrom(params)
        val traceRequested = params.str("traceOutput") != null
        val traceAuto = params.bool("traceAuto")
        val evidenceClient = if (verifySel != null || traceRequested) {
            runCatching { runtimeClientFor(device, pkg, params).also { c -> assertHealthy(c, pkg) } }
                .getOrElse { error ->
                    if (traceAuto && verifySel == null) null else throw error
                }
        } else {
            null
        }
        val traceRecorder = if (traceAuto && evidenceClient == null) {
            null
        } else {
            HelperActionTrace.from(params, pkg, evidenceClient)
        }
        val traceBefore = traceRecorder?.capture()
        val before = verifySel?.let { HelperVerify.captureState(evidenceClient!!, it) }
        var target: ResolvedInputTarget? = null

        val result: JsonObject = when (sub) {
            "tap" -> {
                val first = resolveInputTarget(device, pkg, params)
                target = first
                // Confirm the resolved point has stopped moving BEFORE dispatching.
                //
                // Resolution and dispatch are two steps, and between them the screen
                // can move — not only because the target itself is animating in (the
                // popup case `--settle` was introduced for) but because a PREVIOUS
                // command relayouted the page: a `type` that showed the keyboard, a
                // `hide-keyboard` that took it away, a scroll. Measured on a physical
                // device: a form row tapped by its unique test id resolved to a rect
                // already 161px stale and opened the sheet belonging to the row below
                // it, reporting an unqualified success. Nothing in the result said so,
                // and the trace diff is equally large for the right sheet and the
                // wrong one.
                //
                // So the confirm is now the DEFAULT for selector-based taps rather
                // than opt-in: it costs one extra tree read against a resolution that
                // had to happen anyway, and the failure it prevents is silent and
                // expensive to detect. `--settle` keeps its meaning — give it the full
                // budget, for a target known to be animating — and `--no-settle` opts
                // out for a caller who wants the single-read dispatch.
                var stable: Boolean? = null
                val rawPoint = params.str("point") != null
                if (params.bool("settle") && rawPoint) {
                    throw CliError(
                        "--settle needs a selector: a raw --point has nothing to re-resolve, " +
                            "so there is no way to tell whether it has stopped moving"
                    )
                }
                val plan = TapSettlePolicy.plan(
                    rawPoint = rawPoint,
                    settle = params.bool("settle"),
                    noSettle = params.bool("noSettle"),
                    timeoutMs = params.intOrNull("settleTimeoutMs"),
                )
                if (plan.confirm) {
                    val settled = settleInputTarget(device, pkg, params, first = first, budgetMs = plan.budgetMs)
                    target = settled.target
                    stable = settled.stable
                }
                val x = target!!.point.x.toInt()
                val y = target!!.point.y.toInt()
                input.tap(x, y)
                buildJsonObject {
                    put("gesture", "tap")
                    put("x", x)
                    put("y", y)
                    put("source", target!!.source)
                    target!!.ref?.let { put("ref", it) }
                    // Honest flag, as in scroll-to: false means the target was still
                    // moving when the budget lapsed, so this tap may have been aimed
                    // at a point that had already changed.
                    stable?.let { put("settled", it) }
                    // The evidence that the first read WAS stale: the same selector,
                    // same ref, different coordinates. Without this the confirm would
                    // silently fix the tap and the caller would never learn that the
                    // screen it reasoned about had moved under it.
                    TapSettlePolicy.movedBy(first.point, target!!.point)?.let { put("rectMoved", it) }
                }
            }
            "swipe", "drag" -> {
                val (fx, fy) = parseXY(params.str("from") ?: throw CliError("$sub needs 'from'"))
                val (tx, ty) = parseXY(params.str("to") ?: throw CliError("$sub needs 'to'"))
                val dur = params.intOrNull("duration") ?: if (sub == "drag") 1000 else 300
                if (sub == "drag") input.drag(fx, fy, tx, ty, dur) else input.swipe(fx, fy, tx, ty, dur)
                buildJsonObject { put("gesture", sub); put("from", "$fx,$fy"); put("to", "$tx,$ty"); put("durationMs", dur) }
            }
            "scrollTo", "scroll-to" -> HelperScrollTo.run(input, device, pkg, params)
            "type" -> typeText(input, device, pkg, params)
            "hideKeyboard", "hide-keyboard" -> hideKeyboard(input, device, pkg, params)
            // The one gesture that dispatches no input: it only observes. Kept
            // under `act` because it is part of an action sequence (act, then wait
            // for the consequence) and shares the selector/trace surface.
            "wait" -> HelperWait.run(device, pkg, params)
            else -> throw CliError(
                "unknown act gesture '$sub' (tap/swipe/drag/scroll-to/type/hide-keyboard/wait)"
            )
        }

        val verify = verifySel?.let { HelperVerify.pollForChange(evidenceClient!!, it, before, params) }
        val trace = traceRecorder?.let {
            val settleMs = if (verify == null) (params.intOrNull("traceDelayMs") ?: 250).toLong() else 0L
            it.write(sub, selectorOrNull(params), target, result, traceBefore!!, settleMs)
        }
        if (verify == null && trace == null) return result
        return buildJsonObject {
            result.forEach { (k, v) -> put(k, v) }
            verify?.let { put("verify", it) }
            trace?.let { put("trace", it) }
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
        val agentBytes = pkg?.let {
            val client = runtimeClientFor(device, it, params)
            if (client.probe() is RuntimeHealth.Healthy) captureAgentScreenshot(client)?.also {
                via = "agent /screenshot"
            } else {
                null
            }
        }
        val bytes = agentBytes ?: device.screencap().also {
            if (it.isEmpty()) throw CliError("screencap returned no data (device ready?)")
        }
        return buildJsonObject {
            put("via", via)
            put("pngBase64", Base64.getEncoder().encodeToString(bytes))
            val degraded = pkg?.let { screenshotDegrades(device, it, params, viaAgent = agentBytes != null) }
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
     */
    private fun screenshotDegrades(
        device: DeviceController,
        pkg: String,
        params: JsonObject,
        viaAgent: Boolean,
    ): List<String> = runCatching {
        val client = runtimeClientFor(device, pkg, params)
        if (client.probe() !is RuntimeHealth.Healthy) return emptyList()
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

    private fun typeText(
        input: InputDispatcher,
        device: DeviceController,
        pkg: String,
        params: JsonObject,
    ): JsonObject {
        val text = params.str("text") ?: throw CliError("type needs 'text'")
        // If the caller named a target field, tap it first so the text lands in
        // THAT field. `input text` / paste both go to whatever currently holds
        // focus, so without this a `type --test-id foo` silently typed into the
        // wrong (or no) field. With no target, type into the current focus.
        var focus: ResolvedInputTarget? = null
        if (hasInputTarget(params)) {
            focus = resolveInputTarget(device, pkg, params)
            input.tap(focus.point.x.toInt(), focus.point.y.toInt())
            Thread.sleep(FOCUS_SETTLE_MS)
        }
        val via: String
        if (InputBackend.isAsciiTypeable(text)) {
            input.text(text)
            via = "input text"
        } else {
            val client = runtimeClientFor(device, pkg, params)
            assertHealthy(client, pkg)
            client.setClipboard(text)
            val pasted = input.paste()
            if (!pasted.ok) {
                throw CliError("staged text on clipboard but paste failed: ${pasted.stderr.ifBlank { "no focused input?" }}")
            }
            via = "clipboard paste"
        }
        val submit = if (params.bool("submit")) submitAfterType(input, device, pkg, params) else null
        return buildJsonObject {
            put("gesture", "type"); put("chars", text.length); put("via", via)
            focus?.let { put("focusedVia", it.source); it.ref?.let { r -> put("ref", r) } }
            submit?.let { put("submit", it) }
            keyboardVisibleAfterType(device, pkg, params)?.let { put("keyboardVisible", it) }
        }
    }

    /**
     * Trigger the focused field's submit after `type --submit`. Preferred path
     * is the in-app agent's editor action (TextView.onEditorAction — the exact
     * semantic of the keyboard's Done/Go key, and what React Native's
     * onSubmitEditing listens for); when the agent is unreachable, or answers
     * without a focused field, fall back to KEYCODE_ENTER, which single-line
     * fields translate into the same action.
     */
    private fun submitAfterType(
        input: InputDispatcher,
        device: DeviceController,
        pkg: String,
        params: JsonObject,
    ): JsonObject {
        // Let the field commit the just-typed text before dispatching the action.
        Thread.sleep(FOCUS_SETTLE_MS)
        val client = runtimeClientFor(device, pkg, params)
        if (client.probe() is RuntimeHealth.Healthy) {
            val result = runCatching { client.performEditorAction() }.getOrNull()
            if (result != null && result.performed) {
                return buildJsonObject {
                    put("via", "agent editorAction")
                    result.action?.let { put("action", it) }
                }
            }
        }
        val r = input.keyevent("KEYCODE_ENTER")
        if (!r.ok) {
            throw CliError("typed but submit failed: ${r.stderr.ifBlank { "adb shell did not complete" }}")
        }
        return buildJsonObject { put("via", "keyevent ENTER") }
    }

    /**
     * Opportunistic post-type keyboard probe. Typing almost always leaves the
     * IME up and covering the bottom of the screen — the classic next-step trap
     * is tapping a submit button that is now under the keyboard — so surface
     * that in the type result when the agent can tell us. Null (omitted) when
     * the runtime is unreachable; plain typing must not start failing over an
     * optional status field.
     */
    private fun keyboardVisibleAfterType(
        device: DeviceController,
        pkg: String,
        params: JsonObject,
    ): Boolean? = runCatching {
        val client = runtimeClientFor(device, pkg, params)
        if (client.probe() is RuntimeHealth.Healthy) client.keyboard().visible else null
    }.getOrNull()

    /**
     * Dismiss the system keyboard. Preferred path is the in-app agent's
     * InputMethodManager (deterministic, reports settled before/after state);
     * when the agent is unreachable we fall back to KEYCODE_ESCAPE — unlike
     * KEYCODE_BACK it does not navigate back when the keyboard is already gone.
     */
    private fun hideKeyboard(
        input: InputDispatcher,
        device: DeviceController,
        pkg: String,
        params: JsonObject,
    ): JsonObject {
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
        val r = input.keyevent("KEYCODE_ESCAPE")
        if (!r.ok) {
            throw CliError("agent unreachable and keyevent fallback failed: ${r.stderr.ifBlank { "adb shell did not complete" }}")
        }
        return buildJsonObject {
            put("gesture", "hideKeyboard")
            put("via", "keyevent ESCAPE (agent unreachable; state unknown)")
        }
    }

    /** Whether the caller supplied any field-targeting selector for `type`. */
    private fun hasInputTarget(params: JsonObject): Boolean =
        SELECTOR_KEYS.any { params.str(it) != null }

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

    /** Params [resolveInputTarget]/[selectorFrom] read as a targeting selector. */
    private val SELECTOR_KEYS = listOf(
        "alias", "point", "testId", "resourceId", "css", "cssSelector", "ref", "region",
    )

    /** Time for a tapped field to take focus before we dispatch text. */
    private const val FOCUS_SETTLE_MS = 200L

}
