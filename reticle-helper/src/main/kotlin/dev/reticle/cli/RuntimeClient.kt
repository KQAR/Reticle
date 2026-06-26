package dev.reticle.cli

import dev.reticle.core.SemanticTree
import dev.reticle.core.CompactObservation
import dev.reticle.core.Endpoints
import dev.reticle.core.LogBatch
import dev.reticle.core.MutationRequest
import dev.reticle.core.MutationResult
import dev.reticle.core.ReticleJson
import dev.reticle.core.RuntimeInfo
import dev.reticle.core.Snapshot
import dev.reticle.cli.platform.DeviceController
import java.io.File
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL

/**
 * Host-side client for the in-app loopback server: we first `adb forward` a host
 * port to the device's loopback port, then make plain HTTP calls to 127.0.0.1.
 * The device port is derived from the package via [dev.reticle.core.PortMap].
 */
class RuntimeClient(
    private val adb: DeviceController,
    private val hostPort: Int,
    private val devicePort: Int,
) {

    fun setUpForward() {
        val result = adb.forward(hostPort, devicePort)
        if (!result.ok) {
            throw CliError(
                "adb forward tcp:$hostPort -> tcp:$devicePort failed: ${result.stderr.ifBlank { "is the device connected?" }}"
            )
        }
    }

    fun tearDownForward() {
        adb.removeForward(hostPort)
    }

    fun runtime(): RuntimeInfo =
        ReticleJson.instance.decodeFromString(RuntimeInfo.serializer(), getString(Endpoints.RUNTIME))

    /**
     * Probe the lightweight `/runtime` endpoint and classify the outcome.
     *
     * This is the health/conflict gate the heavier endpoints sit behind.
     * `/runtime` does no UI work (just process metadata), so it answers fast when
     * the agent is alive — which lets us tell apart four very different failures
     * the old code collapsed into one opaque 15s `SocketTimeoutException`:
     *
     *  - [RuntimeHealth.Unreachable]  — connection refused: forward is up but
     *    nothing is listening on the device port (agent not linked / not started).
     *  - [RuntimeHealth.Unresponsive] — connected, but the read timed out: a
     *    zombie listen socket or a hung server thread. This is the exact state we
     *    hit when the forwarded port belonged to a backgrounded process.
     *  - [RuntimeHealth.Foreign]      — answered, but not with a RuntimeInfo: some
     *    other HTTP server (or a different app) is squatting on the port.
     *  - [RuntimeHealth.Healthy]      — a valid RuntimeInfo came back.
     *
     * @param timeoutMillis short per-attempt read timeout; the probe must be cheap.
     */
    fun probe(timeoutMillis: Int = 2500): RuntimeHealth {
        val raw = try {
            getString(Endpoints.RUNTIME, connectTimeout = 1500, readTimeout = timeoutMillis)
        } catch (e: ConnectException) {
            return RuntimeHealth.Unreachable(e.message ?: "connection refused")
        } catch (e: SocketTimeoutException) {
            return RuntimeHealth.Unresponsive(e.message ?: "read timed out")
        } catch (e: Throwable) {
            return RuntimeHealth.Unreachable(e.message ?: e.javaClass.simpleName)
        }
        return try {
            RuntimeHealth.Healthy(ReticleJson.instance.decodeFromString(RuntimeInfo.serializer(), raw))
        } catch (_: Throwable) {
            RuntimeHealth.Foreign(raw.take(120))
        }
    }

    fun snapshot(): Snapshot =
        ReticleJson.instance.decodeFromString(Snapshot.serializer(), getString(Endpoints.SNAPSHOT))

    /**
     * Fetch the semantic tree the agent derives on-device. The CLI itself
     * derives this locally from a single [snapshot] (see uiGroup/resolvePoint) so
     * both trees describe one frame; this method remains for direct protocol use
     * (the `/semantics` endpoint is part of the wire contract).
     */
    @Suppress("unused")
    fun semantics(): SemanticTree =
        ReticleJson.instance.decodeFromString(SemanticTree.serializer(), getString(Endpoints.SEMANTICS))

    /** Compact observation served by the agent. The CLI derives this locally from
     *  [snapshot]; retained for direct use of the `/compact` wire endpoint. */
    @Suppress("unused")
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

    /**
     * Stage [text] on the device clipboard via the in-app agent (the only
     * reliable way to place non-ASCII text). The CLI then dispatches a paste.
     * Body is raw UTF-8; the agent answers "ok" on success.
     */
    fun setClipboard(text: String) {
        post(Endpoints.CLIPBOARD, text, contentType = "text/plain; charset=utf-8")
    }

    // --- HTTP ------------------------------------------------------------

    private fun url(path: String) = URL("http://127.0.0.1:$hostPort$path")

    private fun getString(
        path: String,
        connectTimeout: Int = DEFAULT_CONNECT_TIMEOUT,
        readTimeout: Int = DEFAULT_READ_TIMEOUT,
    ): String {
        val conn = url(path).openConnection() as HttpURLConnection
        conn.requestMethod = "GET"
        conn.connectTimeout = connectTimeout
        conn.readTimeout = readTimeout
        return conn.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
    }

    private fun getBytes(path: String): ByteArray {
        val conn = url(path).openConnection() as HttpURLConnection
        conn.requestMethod = "GET"
        conn.connectTimeout = DEFAULT_CONNECT_TIMEOUT
        conn.readTimeout = DEFAULT_READ_TIMEOUT
        return conn.inputStream.use { it.readBytes() }
    }

    private fun post(path: String, body: String, contentType: String = "application/json"): String {
        val conn = url(path).openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.doOutput = true
        conn.connectTimeout = DEFAULT_CONNECT_TIMEOUT
        conn.readTimeout = DEFAULT_READ_TIMEOUT
        conn.setRequestProperty("Content-Type", contentType)
        conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
        return conn.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
    }

    private companion object {
        const val DEFAULT_CONNECT_TIMEOUT = 5000
        const val DEFAULT_READ_TIMEOUT = 15000
    }
}

/**
 * Classified outcome of probing the in-app server's `/runtime` endpoint. Lets
 * the CLI give a precise diagnosis instead of a raw socket exception.
 */
sealed interface RuntimeHealth {
    /** A valid RuntimeInfo came back. The agent is alive and answering. */
    data class Healthy(val info: RuntimeInfo) : RuntimeHealth

    /** Connection refused — nothing is listening on the forwarded device port. */
    data class Unreachable(val detail: String) : RuntimeHealth

    /** Connected, but no response within the timeout — zombie socket / hung server. */
    data class Unresponsive(val detail: String) : RuntimeHealth

    /** Answered, but not with a RuntimeInfo — some other server is on this port. */
    data class Foreign(val sample: String) : RuntimeHealth
}
