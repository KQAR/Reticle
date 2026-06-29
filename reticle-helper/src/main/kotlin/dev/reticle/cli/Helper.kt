package dev.reticle.cli

import dev.reticle.core.ReticleJson
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
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
        "listDevices" -> HelperDeviceCommands.listDevices()
        "status" -> HelperDeviceCommands.status(params)
        "inject" -> HelperDeviceCommands.inject(params)
        "launch" -> HelperDeviceCommands.launch(params)
        "uiReport" -> HelperDeviceCommands.uiReport(params)
        "act" -> HelperDeviceCommands.act(params)
        "mutate" -> HelperDeviceCommands.mutate(params)
        "logs" -> HelperDeviceCommands.logs(params)
        "logcat" -> HelperDeviceCommands.logcat(params)
        "screenshot" -> HelperDeviceCommands.screenshot(params)
        "render" -> HelperRenderCommands.render(params)
        else -> throw CliError("unknown method '$method'")
    }
}
