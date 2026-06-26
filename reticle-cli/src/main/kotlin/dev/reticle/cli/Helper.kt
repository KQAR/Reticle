package dev.reticle.cli

import dev.reticle.core.CompactObservation
import dev.reticle.core.ReticleJson
import dev.reticle.core.SemanticTree
import dev.reticle.core.Snapshot
import dev.reticle.cli.platform.Platforms
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
        System.err.println("reticle-helper: ready (JSONL stdio RPC)")
        generateSequence(::readLine).forEach { line ->
            if (line.isBlank()) return@forEach
            val response = handleLine(line)
            synchronized(out) {
                out.write(response)
                out.write("\n")
                out.flush()
            }
        }
        System.err.println("reticle-helper: stdin closed, exiting")
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
        "inject" -> inject(params)
        "uiReport" -> uiReport(params)
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

    private fun inject(params: JsonObject): JsonElement {
        val pkg = params.str("package") ?: throw CliError("inject needs 'package'")
        val serial = params.str("serial")
        val device = Platforms.current().device(serial)
        device.ensureDeviceReady()
        val injected = Platforms.current().injector().inject(device, pkg)
        return buildJsonObject {
            put("pid", injected.pid)
            put("reportedPort", injected.reportedPort)
        }
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
        val snapshot: Snapshot = client.snapshot()
        val semantic = SemanticTree.build(snapshot)
        val compact = CompactObservation.from(snapshot)
        return buildJsonObject {
            put("nodeCount", snapshot.nodes.size)
            put("compactItemCount", compact.items.size)
            put("semanticNodeCount", semantic.nodes.size)
        }
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
