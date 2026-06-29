package dev.reticle.cli

import dev.reticle.core.CompactObservation
import dev.reticle.core.MetadataValue
import dev.reticle.core.MutationRequest
import dev.reticle.core.ReticleJson
import dev.reticle.core.SemanticTree
import dev.reticle.core.Snapshot
import dev.reticle.cli.platform.Platforms
import dev.reticle.cli.platform.android.InputBackend
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/**
 * Long-lived stdio RPC server — the Kotlin Android helper a non-JVM host (the
 * planned Swift host) drives across a process boundary. See the roadmap section
 * "Direction: Swift host + per-platform helpers".
 *
 * Protocol: newline-delimited JSON (JSONL), one request per line on stdin, one
 * response per line on stdout. This is deliberately a LONG-LIVED loop, not
 * fork-per-call: the host spawns one helper and reuses it for the whole session,
 * which is what makes high-frequency calls (forward/screencap/input) affordable.
 *
 *   request : {"id": <int>, "method": "<name>", "params": { ... }}
 *   response: {"id": <int>, "ok": true,  "result": { ... }}
 *           | {"id": <int>, "ok": false, "error": "<message>"}
 *
 * Discipline: stdout carries ONLY protocol JSON (so the host can parse it as a
 * clean stream); everything diagnostic goes to stderr. A malformed or unknown
 * request is answered with an error response, never a crash — one bad call must
 * not take the helper down mid-session.
 *
 * This is the spike surface: ping (proves the pipe, no device), listDevices
 * (proves we reach real adb across the boundary), inject and uiReport (the real
 * high-value paths). It reuses the existing Platform SPI and RuntimeClient
 * verbatim — the helper is today's Android host layer behind an RPC seam.
 */
object Helper {

    fun serve() {
        val out = System.out.bufferedWriter()
        // The helper's lifecycle lines (ready / stdin closed) flow straight to the
        // host's stderr, so they print on EVERY command and bracket otherwise-clean
        // output. They're spawn diagnostics, not user-facing — gate them behind
        // RETICLE_DEBUG. Real errors still surface as `ok:false` RPC responses.
        val debug = System.getenv("RETICLE_DEBUG") == "1"
        if (debug) System.err.println("reticle-helper: ready (JSONL stdio RPC)")
        generateSequence(::readLine).forEach { line ->
            if (line.isBlank()) return@forEach
            val response = handleLine(line)
            synchronized(out) {
                out.write(response)
                out.write("\n")
                out.flush()
            }
        }
        if (debug) System.err.println("reticle-helper: stdin closed, exiting")
    }

    private fun handleLine(line: String): String {
        // Parse the envelope defensively: a bad line gets an error response with
        // id=-1 rather than crashing the loop.
        val request = runCatching {
            ReticleJson.compact.parseToJsonElement(line).jsonObject
        }.getOrNull() ?: return errorResponse(-1, "malformed request JSON")

        val id = request["id"]?.jsonPrimitive?.int ?: -1
        val method = request["method"]?.jsonPrimitive?.content
            ?: return errorResponse(id, "missing 'method'")
        val params = request["params"]?.jsonObject ?: JsonObject(emptyMap())

        return try {
            okResponse(id, dispatch(method, params))
        } catch (e: Throwable) {
            errorResponse(id, e.message ?: e.javaClass.simpleName)
        }
    }

    private fun dispatch(method: String, params: JsonObject): JsonElement = when (method) {
        "ping" -> buildJsonObject { put("pong", true); put("version", RETICLE_VERSION) }
        "listDevices" -> listDevices()
        "status" -> status(params)
        "inject" -> inject(params)
        "launch" -> launch(params)
        "uiReport" -> uiReport(params)
        // Device-driving commands (need the runtime / adb).
        "act" -> act(params)
        "mutate" -> mutate(params)
        "logs" -> logs(params)
        "logcat" -> logcat(params)
        "screenshot" -> screenshot(params)
        // Local snapshot rendering (no device; derivation stays here in Kotlin).
        "render" -> render(params)
        else -> throw CliError("unknown method '$method'")
    }

    private fun listDevices(): JsonElement {
        val device = Platforms.current().device(serialOf(null))
        val states = device.listDeviceStates()
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

    private fun status(params: JsonObject): JsonElement {
        val pkg = params.str("package")
        val serial = params.str("serial")
        val device = Platforms.current().device(serial)
        val states = device.listDeviceStates()
        return buildJsonObject {
            put("devices", buildJsonArray {
                states.forEach { s -> add(buildJsonObject { put("serial", s.serial); put("state", s.state) }) }
            })
            if (pkg != null) {
                // Listing devices above is fine with several attached, but probing
                // ONE package's pid/runtime needs an unambiguous target — surface
                // the multi-device error here rather than a misleading "not running".
                device.ensureDeviceReady()
                val pid = device.pidOf(pkg)
                put("package", pkg)
                put("running", pid != null)
                if (pid != null) put("pid", pid)
                val devicePort = params.int("port") ?: dev.reticle.core.PortMap.derivePort(pkg)
                val hostPort = params.int("hostPort") ?: devicePort
                val client = RuntimeClient(device, hostPort, devicePort)
                client.setUpForward()
                put("runtime", when (val h = client.probe()) {
                    is RuntimeHealth.Healthy -> if (h.info.packageName == pkg) "healthy" else "conflict"
                    is RuntimeHealth.Unreachable -> "unreachable"
                    is RuntimeHealth.Unresponsive -> "unresponsive"
                    is RuntimeHealth.Foreign -> "foreign"
                })
            }
        }
    }

    private fun inject(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("inject needs 'package'")
        val serial = params.str("serial")
        // Explicit payload location (the spike showed cwd-relative resolution is
        // a trap when a host spawns the helper from elsewhere). Honored by
        // Injector.locatePayloadDex via the `reticle.payloadDex` system property.
        params.str("payloadDex")?.let { System.setProperty("reticle.payloadDex", it) }
        val device = Platforms.current().device(serial)
        device.ensureDeviceReady()
        val injected = Platforms.current().injector().inject(device, pkg)

        // Mirror `app inject`: the reported port is only a hint. Bootstrap.start()
        // runs when the breakpoint next fires on a live frame, so the real proof
        // is the loopback server answering over HTTP — forward to it and poll
        // /runtime until it's healthy (or time out with a clear message).
        val devicePort = params.int("port") ?: dev.reticle.core.PortMap.derivePort(pkg)
        val hostPort = params.int("hostPort") ?: devicePort
        val client = RuntimeClient(device, hostPort, devicePort)
        client.setUpForward()
        val info = awaitRuntime(client, pkg)
        return buildJsonObject {
            put("pid", info.pid)
            put("packageName", info.packageName)
            put("port", info.port)
            put("agentVersion", info.agentVersion)
            put("reportedPort", injected.reportedPort)
        }
    }

    /** Poll /runtime until the agent for [pkg] answers healthy, else throw. */
    private fun awaitRuntime(client: RuntimeClient, pkg: String, attempts: Int = 40): dev.reticle.core.RuntimeInfo {
        repeat(attempts) {
            when (val health = client.probe()) {
                is RuntimeHealth.Healthy -> if (health.info.packageName == pkg) return health.info
                else -> {}
            }
            Thread.sleep(250)
        }
        throw CliError("timed out waiting for the runtime of '$pkg' to come up after inject")
    }

    private fun uiReport(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("uiReport needs 'package'")
        val serial = params.str("serial")
        val device = Platforms.current().device(serial)
        device.ensureDeviceReady()
        val devicePort = params.int("port") ?: dev.reticle.core.PortMap.derivePort(pkg)
        val hostPort = params.int("hostPort") ?: devicePort
        val client = RuntimeClient(device, hostPort, devicePort)
        client.setUpForward()
        assertHealthy(client, pkg)
        val report = client.report()
        val snapshot = report.snapshot
        val semantic = report.semantics
        val compact = report.compact
        // The agent derives the bundle in-process; the helper just forwards it.
        return buildJsonObject {
            put("nodeCount", snapshot.nodes.size)
            put("compactItemCount", compact.items.size)
            put("semanticNodeCount", semantic.nodes.size)
            put("snapshot", ReticleJson.compact.encodeToJsonElement(Snapshot.serializer(), snapshot))
            put("semantics", ReticleJson.compact.encodeToJsonElement(SemanticTree.serializer(), semantic))
            put("compact", ReticleJson.compact.encodeToJsonElement(CompactObservation.serializer(), compact))
        }
    }

    // --- device-driving methods ----------------------------------------------

    private fun launch(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("launch needs 'package'")
        val serial = params.str("serial")
        val device = Platforms.current().device(serial)
        device.ensureDeviceReady()
        var r = device.shell("monkey -p $pkg -c android.intent.category.LAUNCHER 1")
        if (!r.ok) { Thread.sleep(500); r = device.shell("monkey -p $pkg -c android.intent.category.LAUNCHER 1") }
        if (!r.ok) throw CliError("failed to launch $pkg: ${r.stderr.ifBlank { "adb shell did not complete" }}")
        val devicePort = params.int("port") ?: dev.reticle.core.PortMap.derivePort(pkg)
        val hostPort = params.int("hostPort") ?: devicePort
        val client = RuntimeClient(device, hostPort, devicePort)
        client.setUpForward()
        val info = awaitRuntime(client, pkg)
        return buildJsonObject {
            put("pid", info.pid); put("packageName", info.packageName)
            put("port", info.port); put("agentVersion", info.agentVersion)
        }
    }

    private fun act(params: JsonObject): JsonElement {
        val sub = params.str("gesture") ?: throw CliError("act needs 'gesture'")
        val pkg = params.str("package") ?: throw CliError("act needs 'package'")
        val serial = params.str("serial")
        val device = Platforms.current().device(serial)
        device.ensureDeviceReady()
        val input = Platforms.current().input(device)

        // Optional --verify: watch one node across the gesture so the caller gets
        // "before -> after" in the SAME command, instead of a follow-up full
        // `ui report` + grep. Capture its state now, act, then poll for a change.
        val verifySel = verifySelectorFrom(params)
        val verifyClient = verifySel?.let {
            runtimeClientFor(device, pkg, params).also { c -> assertHealthy(c, pkg) }
        }
        val before = verifyClient?.let { captureVerifyState(it, verifySel!!) }

        val result = when (sub) {
            "tap" -> {
                val point = resolvePoint(device, pkg, params)
                input.tap(point.first, point.second)
                buildJsonObject { put("gesture", "tap"); put("x", point.first); put("y", point.second) }
            }
            "swipe", "drag" -> {
                val (fx, fy) = parseXY(params.str("from") ?: throw CliError("$sub needs 'from'"))
                val (tx, ty) = parseXY(params.str("to") ?: throw CliError("$sub needs 'to'"))
                val dur = params.int("duration") ?: if (sub == "drag") 1000 else 300
                if (sub == "drag") input.drag(fx, fy, tx, ty, dur) else input.swipe(fx, fy, tx, ty, dur)
                buildJsonObject { put("gesture", sub); put("from", "$fx,$fy"); put("to", "$tx,$ty"); put("durationMs", dur) }
            }
            "type" -> {
                val text = params.str("text") ?: throw CliError("type needs 'text'")
                if (InputBackend.isAsciiTypeable(text)) {
                    input.text(text)
                    buildJsonObject { put("gesture", "type"); put("chars", text.length); put("via", "input text") }
                } else {
                    val client = runtimeClientFor(device, pkg, params)
                    assertHealthy(client, pkg)
                    client.setClipboard(text)
                    val pasted = input.paste()
                    if (!pasted.ok) throw CliError("staged text on clipboard but paste failed: ${pasted.stderr.ifBlank { "no focused input?" }}")
                    buildJsonObject { put("gesture", "type"); put("chars", text.length); put("via", "clipboard paste") }
                }
            }
            else -> throw CliError("unknown act gesture '$sub'")
        }

        if (verifyClient == null) return result
        val verify = pollForChange(verifyClient, verifySel!!, before, params)
        return buildJsonObject {
            result.forEach { (k, v) -> put(k, v) }
            put("verify", verify)
        }
    }

    // --- act --verify support -------------------------------------------------

    /**
     * The selector to watch for `--verify`, or null if not requested. `--verify`
     * defaults to the SAME selector being acted on (the common "did the thing I
     * tapped change?"), but accepts an explicit testId/resourceId/ref so you can
     * tap one node and watch another (e.g. tap a term tab, watch `#rata`).
     */
    private fun verifySelectorFrom(params: JsonObject): dev.reticle.core.Selector? {
        val token = params["verify"]?.jsonPrimitive?.content ?: return null
        // "true" means "watch whatever I'm acting on" — reuse the action's own
        // selector. A raw --point has no node to watch, so that's an error.
        if (token == "true") {
            val sel = selectorFrom(params)
            return parseVerifyToken("true", sel.testId, sel.resourceId, sel.ref)
        }
        return parseVerifyToken(token, null, null, null)
    }

    /** Salient, comparable fields of a node for verify diffing. */
    private data class VerifyState(
        val found: Boolean,
        val text: String?,
        val label: String?,
        val enabled: Boolean,
        val visible: Boolean,
        val frame: String?,
        val custom: Map<String, String>,
    )

    private fun selectorParams(sel: dev.reticle.core.Selector): JsonObject = buildJsonObject {
        sel.testId?.let { put("testId", it) }
        sel.resourceId?.let { put("resourceId", it) }
        sel.ref?.let { put("ref", it) }
    }

    private fun captureVerifyState(client: RuntimeClient, sel: dev.reticle.core.Selector): VerifyState {
        val node = findNode(client.snapshot(), selectorParams(sel))
            ?: return VerifyState(false, null, null, false, false, null, emptyMap())
        return VerifyState(
            found = true,
            text = node.text,
            label = node.contentDescription,
            enabled = node.isEnabled,
            visible = node.isVisible,
            frame = node.frame?.let { "${it.x.toInt()},${it.y.toInt()} ${it.width.toInt()}x${it.height.toInt()}" },
            custom = node.custom.mapValues { it.value.displayString() },
        )
    }

    /**
     * Poll the watched node after the gesture and report what changed. UI updates
     * aren't instant, so retry briefly until a diff appears (or the budget runs
     * out — "no change" is itself a real, honest result, not a failure).
     */
    private fun pollForChange(
        client: RuntimeClient,
        sel: dev.reticle.core.Selector,
        before: VerifyState?,
        params: JsonObject,
    ): JsonElement {
        val budgetMs = (params.int("verifyTimeoutMs") ?: 2000).toLong()
        val deadline = System.currentTimeMillis() + budgetMs
        var after = captureVerifyState(client, sel)
        var changes = diffVerify(before, after)
        while (changes.isEmpty() && System.currentTimeMillis() < deadline) {
            Thread.sleep(150)
            after = captureVerifyState(client, sel)
            changes = diffVerify(before, after)
        }
        val selStr = sel.testId?.let { "#$it" } ?: sel.resourceId?.let { "@$it" } ?: sel.ref ?: "?"
        return buildJsonObject {
            put("selector", selStr)
            put("changed", changes.isNotEmpty())
            if (!after.found) put("note", "node not present after action")
            put("changes", buildJsonArray {
                changes.forEach { (field, ba) ->
                    add(buildJsonObject { put("field", field); put("before", ba.first); put("after", ba.second) })
                }
            })
        }
    }

    /** Field-by-field diff of two verify states; key -> (before, after). */
    private fun diffVerify(before: VerifyState?, after: VerifyState): Map<String, Pair<String?, String?>> {
        if (before == null) return emptyMap()
        val out = LinkedHashMap<String, Pair<String?, String?>>()
        if (before.found != after.found) out["present"] = before.found.toString() to after.found.toString()
        if (before.text != after.text) out["text"] = before.text to after.text
        if (before.label != after.label) out["label"] = before.label to after.label
        if (before.enabled != after.enabled) out["enabled"] = before.enabled.toString() to after.enabled.toString()
        if (before.visible != after.visible) out["visible"] = before.visible.toString() to after.visible.toString()
        if (before.frame != after.frame) out["frame"] = before.frame to after.frame
        (before.custom.keys + after.custom.keys).forEach { k ->
            val b = before.custom[k]; val a = after.custom[k]
            if (b != a) out[k] = b to a
        }
        return out
    }

    private fun mutate(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("mutate needs 'package'")
        val property = params.str("property") ?: throw CliError("mutate needs 'property'")
        val rawValue = params.str("value") ?: throw CliError("mutate needs 'value'")
        val serial = params.str("serial")
        val device = Platforms.current().device(serial)
        device.ensureDeviceReady()
        val devicePort = params.int("port") ?: dev.reticle.core.PortMap.derivePort(pkg)
        val hostPort = params.int("hostPort") ?: devicePort
        val client = RuntimeClient(device, hostPort, devicePort)
        client.setUpForward()
        assertHealthy(client, pkg)
        val request = MutationRequest(selectorFrom(params), property, parseValue(rawValue))
        val result = client.mutate(request)
        if (!result.applied) throw CliError(result.message ?: "mutation failed")
        return buildJsonObject {
            put("applied", true); put("ref", result.ref)
            put("previousValue", result.previousValue?.displayString())
        }
    }

    private fun logs(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("logs needs 'package'")
        val serial = params.str("serial")
        val device = Platforms.current().device(serial)
        device.ensureDeviceReady()
        val devicePort = params.int("port") ?: dev.reticle.core.PortMap.derivePort(pkg)
        val hostPort = params.int("hostPort") ?: devicePort
        val client = RuntimeClient(device, hostPort, devicePort)
        client.setUpForward()
        assertHealthy(client, pkg)
        val batch = client.logs()
        return buildJsonObject {
            put("entries", buildJsonArray {
                batch.entries.forEach { e ->
                    add(buildJsonObject { put("level", e.level); put("message", e.message) })
                }
            })
        }
    }

    private fun logcat(params: JsonObject): JsonElement {
        val serial = params.str("serial")
        val device = Platforms.current().device(serial)
        val lines = device.agentLog()
        return buildJsonObject {
            put("lines", buildJsonArray { lines.forEach { add(JsonPrimitive(it)) } })
        }
    }

    private fun screenshot(params: JsonObject): JsonElement {
        val pkg = params.str("package")
        val serial = params.str("serial")
        val device = Platforms.current().device(serial)
        device.ensureDeviceReady()
        // Prefer the agent's /screenshot when reachable; else fall back to
        // `adb exec-out screencap` (honest degraded mode, no agent needed).
        var via = "adb screencap"
        var bytes: ByteArray? = null
        if (pkg != null) {
            val devicePort = params.int("port") ?: dev.reticle.core.PortMap.derivePort(pkg)
            val hostPort = params.int("hostPort") ?: devicePort
            val client = RuntimeClient(device, hostPort, devicePort)
            client.setUpForward()
            if (client.probe() is RuntimeHealth.Healthy) {
                val tmp = java.io.File.createTempFile("reticle-shot", ".png")
                runCatching { client.screenshot(tmp) }.onSuccess {
                    bytes = tmp.readBytes(); via = "agent /screenshot"
                }
                tmp.delete()
            }
        }
        if (bytes == null) {
            val raw = device.screencap()
            if (raw.isEmpty()) throw CliError("screencap returned no data (device ready?)")
            bytes = raw
        }
        return buildJsonObject {
            put("via", via)
            put("pngBase64", java.util.Base64.getEncoder().encodeToString(bytes))
        }
    }

    // --- snapshot rendering ----------------------------------------------------

    /**
     * Render a view of a snapshot to text. The snapshot comes from one of two
     * sources, chosen by params:
     *  - a `snapshot` file path (local, no device) — the default for inspecting a
     *    saved report;
     *  - `live: true` + a `package` — fetch the CURRENT tree from the runtime and
     *    render it WITHOUT writing any files. This is the cheap "did that node
     *    change?" path: one round-trip, no 369-node report on disk to grep.
     */
    private fun render(params: JsonObject): JsonElement {
        val view = params.str("view") ?: throw CliError("render needs 'view'")
        val snapshot = snapshotFor(params)
        val text = renderView(view, snapshot, params)
        return buildJsonObject { put("text", text) }
    }

    /** Resolve the snapshot a render should operate on: live runtime or a file. */
    private fun snapshotFor(params: JsonObject): Snapshot {
        if (params["live"]?.jsonPrimitive?.content == "true") {
            val pkg = params.str("package")
                ?: throw CliError("live render needs 'package'")
            val serial = params.str("serial")
            val device = Platforms.current().device(serial)
            device.ensureDeviceReady()
            val devicePort = params.int("port") ?: dev.reticle.core.PortMap.derivePort(pkg)
            val hostPort = params.int("hostPort") ?: devicePort
            val client = RuntimeClient(device, hostPort, devicePort)
            client.setUpForward()
            assertHealthy(client, pkg)
            return client.snapshot()
        }
        val path = params.str("snapshot") ?: throw CliError("render needs 'snapshot' path (or live + package)")
        val file = java.io.File(path)
        if (!file.exists()) throw CliError("snapshot file not found: $path")
        return ReticleJson.instance.decodeFromString(Snapshot.serializer(), file.readText())
    }

    private fun renderView(view: String, snapshot: Snapshot, params: JsonObject): String = when (view) {
        "tree" -> renderViewTree(snapshot, params.int("depth") ?: Int.MAX_VALUE)
        "semantics" -> renderSemanticTree(SemanticTree.build(snapshot), params.int("depth") ?: Int.MAX_VALUE)
        "compact" -> CompactObservation.from(snapshot).items.joinToString("\n") { it.line() }
        "node" -> renderNode(snapshot, params)
        "regions" -> renderRegions(snapshot)
        else -> throw CliError("unknown render view '$view'")
    }

    private fun renderNode(snapshot: Snapshot, params: JsonObject): String {
        val node = findNode(snapshot, params) ?: throw CliError("no matching node")
        return ReticleJson.instance.encodeToString(dev.reticle.core.Node.serializer(), node)
    }

    /** Locate a node in [snapshot] by testId / resourceId / ref, or null. */
    private fun findNode(snapshot: Snapshot, params: JsonObject): dev.reticle.core.Node? {
        val testId = params.str("testId")
        val resourceId = params.str("resourceId")
        val ref = params.str("ref")
        return when {
            testId != null -> snapshot.nodes.values.firstOrNull { it.testId == testId }
            resourceId != null -> snapshot.nodes.values.firstOrNull { it.resourceId == resourceId }
            ref != null -> snapshot.nodes[ref]
            else -> throw CliError("node needs testId, resourceId, or ref")
        }
    }

    private fun renderViewTree(snapshot: Snapshot, maxDepth: Int): String = buildString {
        fun walk(ref: String, depth: Int) {
            if (depth > maxDepth) return
            val node = snapshot.nodes[ref] ?: return
            val sel = node.testId?.let { "#$it" } ?: node.resourceId?.let { "@$it" } ?: node.ref
            val label = node.text ?: node.contentDescription
            append("  ".repeat(depth)).append("$sel ${node.role ?: node.typeName}${label?.let { " \"${it.take(30)}\"" } ?: ""}").append("\n")
            node.children.forEach { walk(it, depth + 1) }
        }
        walk(snapshot.rootRef, 0)
    }.trimEnd()

    private fun renderSemanticTree(tree: SemanticTree, maxDepth: Int): String = buildString {
        fun walk(ref: String, depth: Int) {
            if (depth > maxDepth) return
            val node = tree.nodes[ref] ?: return
            val sel = node.testId?.let { "#$it" } ?: node.resourceId?.let { "@$it" } ?: node.ref
            append("  ".repeat(depth)).append("$sel ${node.role}${node.label?.let { " \"${it.take(30)}\"" } ?: ""}").append("\n")
            node.children.forEach { walk(it, depth + 1) }
        }
        val roots = tree.nodes.values.filter { it.parentRef == null || !tree.nodes.containsKey(it.parentRef) }.map { it.ref }
        if (roots.isEmpty()) append("(no semantic nodes)") else roots.forEach { walk(it, 0) }
    }.trimEnd()

    private fun renderRegions(snapshot: Snapshot): String = buildString {
        var any = false
        for (node in snapshot.nodes.values) {
            if (node.regions.isEmpty() && !node.suspectedMultiRegion) continue
            any = true
            val sel = node.testId?.let { "#$it" } ?: node.resourceId?.let { "@$it" } ?: node.ref
            append("$sel ${node.role ?: node.typeName}${node.text?.let { " \"${it.take(40)}\"" } ?: ""}").append("\n")
            if (node.suspectedMultiRegion) {
                append("    ⚠ suspectedMultiRegion: self-drawn control\n")
                node.charGrid?.let { g -> append("    charGrid: ${g.lines.size} line(s)${if (g.approximate) " (approximate)" else ""}\n") }
            }
            for (r in node.regions) {
                val rect = r.rects.firstOrNull()
                val where = rect?.let { "[${it.x.toInt()},${it.y.toInt()} ${it.width.toInt()}x${it.height.toInt()}]" } ?: "(no rect)"
                append("    • ${r.source} \"${r.label?.take(40) ?: ""}\"${r.target?.let { " -> $it" } ?: ""}${r.color?.let { " color=$it" } ?: ""} $where\n")
            }
        }
        if (!any) append("(no multi-region nodes found)")
    }.trimEnd()

    // --- shared helpers for the methods above ---------------------------------

    /** A forward-ready RuntimeClient for [pkg], honoring optional port overrides. */
    private fun runtimeClientFor(
        device: dev.reticle.cli.platform.DeviceController,
        pkg: String,
        params: JsonObject,
    ): RuntimeClient {
        val devicePort = params.int("port") ?: dev.reticle.core.PortMap.derivePort(pkg)
        val hostPort = params.int("hostPort") ?: devicePort
        return RuntimeClient(device, hostPort, devicePort).also { it.setUpForward() }
    }

    private fun assertHealthy(client: RuntimeClient, pkg: String) {
        when (val h = client.probe()) {
            is RuntimeHealth.Healthy -> if (h.info.packageName != pkg)
                throw CliError("port conflict: served by '${h.info.packageName}', not '$pkg'")
            is RuntimeHealth.Unreachable -> throw CliError("no Reticle runtime for '$pkg' (connection refused). Inject or launch first.")
            is RuntimeHealth.Unresponsive -> throw CliError("runtime for '$pkg' connected but did not respond (${h.detail})")
            is RuntimeHealth.Foreign -> throw CliError("port answered but not as a Reticle runtime (${h.sample})")
        }
    }

    private fun resolvePoint(device: dev.reticle.cli.platform.DeviceController, pkg: String, params: JsonObject): Pair<Int, Int> {
        params.str("point")?.let { return parseXY(it) }
        val client = runtimeClientFor(device, pkg, params)
        assertHealthy(client, pkg)
        val snapshot = client.snapshot()
        val semantic = SemanticTree.build(snapshot)
        val resolved = SelectorResolver(snapshot, semantic).resolve(selectorFrom(params))
            ?: throw CliError("could not resolve selector to a point")
        System.err.println("reticle-helper: resolved via ${resolved.source} -> ref=${resolved.ref}")
        return resolved.point.x.toInt() to resolved.point.y.toInt()
    }

    private fun selectorFrom(params: JsonObject): dev.reticle.core.Selector = dev.reticle.core.Selector(
        testId = params.str("testId"),
        resourceId = params.str("resourceId"),
        ref = params.str("ref"),
        point = params.str("point")?.let { val (x, y) = parseXY(it); dev.reticle.core.Point(x.toDouble(), y.toDouble()) },
        region = params.str("region"),
    )

    private fun parseXY(value: String): Pair<Int, Int> {
        val parts = value.split(",")
        if (parts.size != 2) throw CliError("expected x,y but got '$value'")
        return parts[0].trim().toInt() to parts[1].trim().toInt()
    }

    private fun parseValue(raw: String): MetadataValue = when {
        raw == "true" || raw == "false" -> MetadataValue.Bool(raw.toBoolean())
        raw.toLongOrNull() != null -> MetadataValue.Integer(raw.toLong())
        raw.toDoubleOrNull() != null -> MetadataValue.Real(raw.toDouble())
        else -> MetadataValue.Text(raw)
    }

    // --- envelope helpers ----------------------------------------------------

    private fun okResponse(id: Int, result: JsonElement): String =
        ReticleJson.compact.encodeToString(
            JsonElement.serializer(),
            buildJsonObject {
                put("id", id)
                put("ok", true)
                put("result", result)
            }
        )

    private fun errorResponse(id: Int, message: String): String =
        ReticleJson.compact.encodeToString(
            JsonElement.serializer(),
            buildJsonObject {
                put("id", id)
                put("ok", false)
                put("error", message)
            }
        )

    private fun serialOf(explicit: String?): String? = explicit
    private fun JsonObject.str(key: String): String? = this[key]?.jsonPrimitive?.content
    private fun JsonObject.int(key: String): Int? = this[key]?.jsonPrimitive?.content?.toIntOrNull()
}

/**
 * Resolve a `--verify` token into the node selector to watch. Pure so it can be
 * unit-tested without a device.
 *  - "false" -> null (not requested)
 *  - "true"  -> the action's own selector, supplied via [actTestId]/[actResourceId]/[actRef];
 *               null if the action had no node selector (e.g. a raw --point).
 *  - "#id"   -> testId, "@res" -> resourceId, anything else -> a raw ref.
 */
internal fun parseVerifyToken(
    token: String,
    actTestId: String?,
    actResourceId: String?,
    actRef: String?,
): dev.reticle.core.Selector? = when {
    token == "false" -> null
    token == "true" -> {
        if (actTestId == null && actResourceId == null && actRef == null) {
            throw CliError("--verify needs a node selector to watch: pass --verify <#testId|@resourceId|ref>, or act by selector rather than --point")
        }
        dev.reticle.core.Selector(testId = actTestId, resourceId = actResourceId, ref = actRef)
    }
    token.startsWith("#") -> dev.reticle.core.Selector(testId = token.drop(1))
    token.startsWith("@") -> dev.reticle.core.Selector(resourceId = token.drop(1))
    else -> dev.reticle.core.Selector(ref = token)
}
