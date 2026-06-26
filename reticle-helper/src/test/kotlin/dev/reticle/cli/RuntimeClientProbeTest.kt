package dev.reticle.cli

import dev.reticle.cli.platform.android.Adb
import java.io.OutputStream
import java.net.ServerSocket
import kotlin.concurrent.thread
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

/**
 * Tests for [RuntimeClient.probe] — the health/conflict classifier. The probe
 * talks plain HTTP to 127.0.0.1:<hostPort> (in production an `adb forward`
 * target), so we can exercise every branch with a local [ServerSocket]; no adb
 * or device involved.
 */
class RuntimeClientProbeTest {

    private var server: ServerSocket? = null

    @AfterTest
    fun tearDown() {
        server?.close()
    }

    /** Find a free port, then start a server whose handler writes a raw response. */
    private fun serveOn(handler: (OutputStream) -> Unit): Int {
        val socket = ServerSocket(0)
        server = socket
        thread(isDaemon = true) {
            while (!socket.isClosed) {
                val client = try { socket.accept() } catch (_: Throwable) { break }
                thread(isDaemon = true) {
                    client.use { c ->
                        // Drain the request line/headers so the client can finish writing.
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

    @Test
    fun healthyWhenServerReturnsRuntimeInfo() {
        val port = serveOn(http200(
            """{"packageName":"dev.reticle.sample","processName":"dev.reticle.sample","pid":42,"sdkInt":35,"agentVersion":"0.1.0","port":8765}"""
        ))
        val health = clientFor(port).probe(timeoutMillis = 2000)
        val healthy = assertIs<RuntimeHealth.Healthy>(health)
        assertEquals("dev.reticle.sample", healthy.info.packageName)
        assertEquals(42, healthy.info.pid)
    }

    @Test
    fun foreignWhenServerReturnsNonRuntimeJson() {
        val port = serveOn(http200("""{"hello":"world"}"""))
        val health = clientFor(port).probe(timeoutMillis = 2000)
        assertIs<RuntimeHealth.Foreign>(health)
    }

    @Test
    fun unreachableWhenNothingListens() {
        // Grab a port, then close it so connects are refused.
        val socket = ServerSocket(0)
        val port = socket.localPort
        socket.close()
        val health = clientFor(port).probe(timeoutMillis = 2000)
        assertIs<RuntimeHealth.Unreachable>(health)
    }

    @Test
    fun unresponsiveWhenServerAcceptsButNeverReplies() {
        // Accept the connection but never write a response → read times out.
        val port = serveOn { /* write nothing; just hold the socket open briefly */
            Thread.sleep(4000)
        }
        val health = clientFor(port).probe(timeoutMillis = 600)
        assertIs<RuntimeHealth.Unresponsive>(health)
    }
}
