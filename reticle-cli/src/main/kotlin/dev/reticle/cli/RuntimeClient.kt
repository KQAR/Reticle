package dev.reticle.cli

import dev.reticle.core.AccessibilityTree
import dev.reticle.core.CompactObservation
import dev.reticle.core.Endpoints
import dev.reticle.core.LogBatch
import dev.reticle.core.MutationRequest
import dev.reticle.core.MutationResult
import dev.reticle.core.ReticleJson
import dev.reticle.core.RuntimeInfo
import dev.reticle.core.Snapshot
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * Host-side client for the in-app loopback server: we first `adb forward` a host
 * port to the device's loopback port, then make plain HTTP calls to 127.0.0.1.
 *
 * The serial+package -> port mapping is stored under ~/.reticle/runtimes via
 * RuntimeRegistry.
 */
class RuntimeClient(
    private val adb: Adb,
    private val hostPort: Int,
    private val devicePort: Int,
) {

    fun setUpForward() {
        val result = adb.forward(hostPort, devicePort)
        check(result.ok) { "adb forward tcp:$hostPort tcp:$devicePort failed: ${result.stderr}" }
    }

    fun tearDownForward() {
        adb.removeForward(hostPort)
    }

    fun runtime(): RuntimeInfo =
        ReticleJson.instance.decodeFromString(RuntimeInfo.serializer(), getString(Endpoints.RUNTIME))

    fun snapshot(): Snapshot =
        ReticleJson.instance.decodeFromString(Snapshot.serializer(), getString(Endpoints.SNAPSHOT))

    fun accessibility(): AccessibilityTree =
        ReticleJson.instance.decodeFromString(AccessibilityTree.serializer(), getString(Endpoints.ACCESSIBILITY))

    fun compact(): CompactObservation =
        ReticleJson.instance.decodeFromString(CompactObservation.serializer(), getString(Endpoints.COMPACT))

    fun logs(): LogBatch =
        ReticleJson.instance.decodeFromString(LogBatch.serializer(), getString(Endpoints.LOGS))

    fun screenshot(into: File) {
        val bytes = getBytes(Endpoints.SCREENSHOT)
        into.writeBytes(bytes)
    }

    fun mutate(request: MutationRequest): MutationResult {
        val body = ReticleJson.compact.encodeToString(MutationRequest.serializer(), request)
        val response = post(Endpoints.MUTATE, body)
        return ReticleJson.instance.decodeFromString(MutationResult.serializer(), response)
    }

    // --- HTTP ------------------------------------------------------------

    private fun url(path: String) = URL("http://127.0.0.1:$hostPort$path")

    private fun getString(path: String): String {
        val conn = url(path).openConnection() as HttpURLConnection
        conn.requestMethod = "GET"
        conn.connectTimeout = 5000
        conn.readTimeout = 15000
        return conn.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
    }

    private fun getBytes(path: String): ByteArray {
        val conn = url(path).openConnection() as HttpURLConnection
        conn.requestMethod = "GET"
        conn.connectTimeout = 5000
        conn.readTimeout = 15000
        return conn.inputStream.use { it.readBytes() }
    }

    private fun post(path: String, body: String): String {
        val conn = url(path).openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.doOutput = true
        conn.connectTimeout = 5000
        conn.readTimeout = 15000
        conn.setRequestProperty("Content-Type", "application/json")
        conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        return conn.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
    }
}
