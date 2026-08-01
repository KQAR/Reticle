package dev.reticle.cli

import dev.reticle.cli.platform.android.Adb
import java.io.OutputStream
import java.net.ServerSocket
import kotlin.concurrent.thread
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * Tests for [awaitRuntime]'s wall-clock deadline. The budget used to be an
 * attempt COUNT, which let an Unresponsive port (each probe burning its whole
 * read timeout) stretch 40 attempts into minutes of wall clock. The clock and
 * sleep are injected, so the deadline is checked without waiting it out; the
 * probe targets a real local socket, [RuntimeClientProbeTest]-style.
 */
class AwaitRuntimeTest {

    private var server: ServerSocket? = null

    @AfterTest
    fun tearDown() {
        server?.close()
    }

    private fun serveOn(handler: (OutputStream) -> Unit): Int {
        val socket = ServerSocket(0)
        server = socket
        thread(isDaemon = true) {
            while (!socket.isClosed) {
                val client = try { socket.accept() } catch (_: Throwable) { break }
                thread(isDaemon = true) {
                    client.use { c ->
                        runCatching {
                            val input = c.getInputStream().bufferedReader()
                            while (true) {
                                val line = input.readLine() ?: break
                                if (line.isEmpty()) break
                            }
                        }
                        runCatching { handler(c.getOutputStream()) }
                    }
                }
            }
        }
        return socket.localPort
    }

    private fun http200(body: String): (OutputStream) -> Unit = { out ->
        val bytes = body.toByteArray(Charsets.UTF_8)
        out.write(
            ("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\n" +
                "Connection: close\r\n\r\n").toByteArray(Charsets.UTF_8)
        )
        out.write(bytes)
        out.flush()
    }

    private fun clientFor(port: Int) = RuntimeClient(Adb(adbPath = "/bin/true"), hostPort = port, devicePort = port)

    /** A closed port: every probe answers Unreachable, fast. */
    private fun closedPort(): Int {
        val socket = ServerSocket(0)
        val port = socket.localPort
        socket.close()
        return port
    }

    @Test
    fun returnsTheRuntimeInfoWhenTheAgentAnswersHealthy() {
        val port = serveOn(http200(
            """{"packageName":"dev.reticle.sample","processName":"dev.reticle.sample","pid":42,"sdkInt":35,"agentVersion":"0.1.0","port":8765}"""
        ))
        val info = awaitRuntime(clientFor(port), "dev.reticle.sample", timeoutMs = 5_000L, sleep = {})
        assertEquals(42, info.pid)
    }

    @Test
    fun givesUpAtTheWallClockDeadlineNotAnAttemptCount() {
        var clock = 0L
        var probes = 0
        val error = assertFailsWith<CliError> {
            awaitRuntime(
                clientFor(closedPort()),
                "dev.reticle.sample",
                timeoutMs = 1_000L,
                nowMs = { clock },
                // Model each probe+sleep cycle costing 500ms of wall clock — the
                // loaded-host case where an attempt count would keep going.
                sleep = { probes += 1; clock += 500L },
            )
        }
        assertEquals(2, probes, "a 1s budget at 500ms per cycle is two probes, not forty")
        assertTrue(error.message!!.contains("timed out after 1000ms"), error.message)
    }

    @Test
    fun timeoutErrorNamesTheLastObservedState() {
        var clock = 0L
        val error = assertFailsWith<CliError> {
            awaitRuntime(
                clientFor(closedPort()),
                "dev.reticle.sample",
                timeoutMs = 500L,
                nowMs = { clock },
                sleep = { clock += 250L },
            )
        }
        assertTrue(
            error.message!!.contains("unreachable"),
            "the error must say what the port looked like when we gave up: ${error.message}"
        )
    }

    @Test
    fun timeoutErrorNamesTheForeignPackageServingThePort() {
        // Healthy probe, wrong package: the classic port conflict. The timeout
        // must name the squatter, not just say "timed out".
        val port = serveOn(http200(
            """{"packageName":"com.example.squatter","processName":"com.example.squatter","pid":7,"sdkInt":35,"agentVersion":"0.1.0","port":8765}"""
        ))
        var clock = 0L
        val error = assertFailsWith<CliError> {
            awaitRuntime(
                clientFor(port),
                "dev.reticle.sample",
                timeoutMs = 500L,
                nowMs = { clock },
                sleep = { clock += 250L },
            )
        }
        assertTrue(error.message!!.contains("com.example.squatter"), error.message)
    }
}
