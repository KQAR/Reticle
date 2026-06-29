package dev.reticle.cli

import dev.reticle.cli.platform.InputDispatcher
import dev.reticle.cli.platform.Platforms
import dev.reticle.cli.platform.android.InputBackend
import dev.reticle.core.CompactObservation
import dev.reticle.core.MutationRequest
import dev.reticle.core.ReticleJson
import dev.reticle.core.SemanticTree
import dev.reticle.core.Snapshot
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File
import java.util.Base64

/** Device/runtime-backed helper RPC commands. */
internal object HelperDeviceCommands {
    fun listDevices(): JsonElement {
        val states = Platforms.current().device(null).listDeviceStates()
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
        val device = Platforms.current().device(params.str("serial"))
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
        val device = Platforms.current().device(params.str("serial"))
        device.ensureDeviceReady()
        val injected = Platforms.current().injector().inject(device, pkg)
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
        val device = Platforms.current().device(params.str("serial"))
        device.ensureDeviceReady()
        val client = runtimeClientFor(device, pkg, params)
        assertHealthy(client, pkg)
        val report = client.report()
        return reportJson(report.snapshot, report.semantics, report.compact)
    }

    fun launch(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("launch needs 'package'")
        val device = Platforms.current().device(params.str("serial"))
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
        val device = Platforms.current().device(params.str("serial"))
        device.ensureDeviceReady()
        val input = Platforms.current().input(device)

        val verifySel = HelperVerify.watchSelectorFrom(params)
        val traceRequested = params.str("traceOutput") != null
        val evidenceClient = if (verifySel != null || traceRequested) {
            runtimeClientFor(device, pkg, params).also { c -> assertHealthy(c, pkg) }
        } else {
            null
        }
        val traceRecorder = HelperActionTrace.from(params, pkg, evidenceClient)
        val traceBefore = traceRecorder?.capture()
        val before = verifySel?.let { HelperVerify.captureState(evidenceClient!!, it) }
        var target: ResolvedInputTarget? = null

        val result: JsonObject = when (sub) {
            "tap" -> {
                target = resolveInputTarget(device, pkg, params)
                val x = target!!.point.x.toInt()
                val y = target!!.point.y.toInt()
                input.tap(x, y)
                buildJsonObject {
                    put("gesture", "tap")
                    put("x", x)
                    put("y", y)
                    put("source", target!!.source)
                    target!!.ref?.let { put("ref", it) }
                }
            }
            "swipe", "drag" -> {
                val (fx, fy) = parseXY(params.str("from") ?: throw CliError("$sub needs 'from'"))
                val (tx, ty) = parseXY(params.str("to") ?: throw CliError("$sub needs 'to'"))
                val dur = params.intOrNull("duration") ?: if (sub == "drag") 1000 else 300
                if (sub == "drag") input.drag(fx, fy, tx, ty, dur) else input.swipe(fx, fy, tx, ty, dur)
                buildJsonObject { put("gesture", sub); put("from", "$fx,$fy"); put("to", "$tx,$ty"); put("durationMs", dur) }
            }
            "type" -> typeText(input, device, pkg, params)
            else -> throw CliError("unknown act gesture '$sub'")
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
        val device = Platforms.current().device(params.str("serial"))
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
        val device = Platforms.current().device(params.str("serial"))
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
        val lines = Platforms.current().device(params.str("serial")).agentLog()
        return buildJsonObject {
            put("lines", buildJsonArray { lines.forEach { add(it) } })
        }
    }

    fun screenshot(params: JsonObject): JsonElement {
        val pkg = params.str("package")
        val device = Platforms.current().device(params.str("serial"))
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
        }
    }

    private fun typeText(
        input: InputDispatcher,
        device: dev.reticle.cli.platform.DeviceController,
        pkg: String,
        params: JsonObject,
    ): JsonObject {
        val text = params.str("text") ?: throw CliError("type needs 'text'")
        if (InputBackend.isAsciiTypeable(text)) {
            input.text(text)
            return buildJsonObject { put("gesture", "type"); put("chars", text.length); put("via", "input text") }
        }
        val client = runtimeClientFor(device, pkg, params)
        assertHealthy(client, pkg)
        client.setClipboard(text)
        val pasted = input.paste()
        if (!pasted.ok) {
            throw CliError("staged text on clipboard but paste failed: ${pasted.stderr.ifBlank { "no focused input?" }}")
        }
        return buildJsonObject { put("gesture", "type"); put("chars", text.length); put("via", "clipboard paste") }
    }

    private fun reportJson(snapshot: Snapshot, semantic: SemanticTree, compact: CompactObservation): JsonElement =
        buildJsonObject {
            put("nodeCount", snapshot.nodes.size)
            put("compactItemCount", compact.items.size)
            put("semanticNodeCount", semantic.nodes.size)
            put("snapshot", ReticleJson.compact.encodeToJsonElement(Snapshot.serializer(), snapshot))
            put("semantics", ReticleJson.compact.encodeToJsonElement(SemanticTree.serializer(), semantic))
            put("compact", ReticleJson.compact.encodeToJsonElement(CompactObservation.serializer(), compact))
        }

    private fun captureAgentScreenshot(client: RuntimeClient): ByteArray? {
        val tmp = File.createTempFile("reticle-shot", ".png")
        return try {
            runCatching { client.screenshot(tmp) }
                .map { tmp.readBytes() }
                .getOrNull()
        } finally {
            tmp.delete()
        }
    }
}
