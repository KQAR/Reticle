package dev.reticle.cli

import dev.reticle.cli.platform.CommandResult
import dev.reticle.cli.platform.DeviceController
import dev.reticle.cli.platform.DeviceState
import java.net.ServerSocket
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

/**
 * Tests for the forward cache in [runtimeClientFor] / [ForwardRegistry], and its
 * self-healing half in [RuntimeClient].
 *
 * The `adb forward` fork (30-80ms) used to run on EVERY client build, although
 * the forward it sets up lives on the persistent adb server — and the hot paths
 * (tap-confirm settle loop, type read-back) build a client per poll. The cache
 * must therefore skip the fork when the mapping is already recorded, and a
 * recorded forward that no longer exists (killed externally, or recorded by an
 * earlier client while adb restarted) must re-establish itself instead of
 * poisoning the rest of the session.
 */
class ForwardRegistryTest {

    /** Counts forwards instead of running adb; every other call is inert. */
    private class ForwardCountingDevice(override val serialOrNull: String? = "test-serial") : DeviceController {
        val forwarded = mutableListOf<Pair<Int, Int>>()
        val removed = mutableListOf<Int>()

        override fun forward(hostPort: Int, devicePort: Int): CommandResult {
            forwarded.add(hostPort to devicePort)
            return CommandResult(0, "", "")
        }

        override fun removeForward(hostPort: Int): CommandResult {
            removed.add(hostPort)
            return CommandResult(0, "", "")
        }

        override fun run(vararg args: String, timeoutSeconds: Long) = CommandResult(0, "", "")
        override fun runBytes(vararg args: String, timeoutSeconds: Long) = ByteArray(0)
        override fun shell(command: String, timeoutSeconds: Long) = CommandResult(0, "", "")
        override fun forwardJdwp(hostPort: Int, pid: Int) = CommandResult(0, "", "")
        override fun runAs(packageName: String, vararg args: String, timeoutSeconds: Long) =
            CommandResult(0, "", "")
        override fun listDevices() = listOf("test-serial")
        override fun listDeviceStates() = listOf(DeviceState("test-serial", "device"))
        override fun pidOf(packageName: String): Int? = null
        override fun screencap(timeoutSeconds: Long) = ByteArray(0)
        override fun deviceState(): String? = "device"
        override fun ensureDeviceReady(retries: Int) {}
        override fun agentLog(maxLines: Int) = emptyList<String>()
    }

    @AfterTest
    fun tearDown() {
        // The registry is session-global; leave nothing behind for other tests.
        ForwardRegistry.cleanup()
    }

    /** A port with nothing listening on it, so connects are refused. */
    private fun closedPort(): Int = ServerSocket(0).use { it.localPort }

    @Test
    fun secondClientForTheSameMappingSkipsTheAdbForward() {
        val device = ForwardCountingDevice()
        val params = jsonParams(port = 18888)
        runtimeClientFor(device, "com.example.app", params)
        runtimeClientFor(device, "com.example.app", params)
        assertEquals(
            listOf(18888 to 18888), device.forwarded,
            "the registry already records this mapping; the second build must not fork adb"
        )
    }

    @Test
    fun aDifferentDevicePortOnTheSameHostPortIsNotACacheHit() {
        val device = ForwardCountingDevice()
        runtimeClientFor(device, "com.example.app", jsonParams(port = 18888, hostPort = 18000))
        runtimeClientFor(device, "com.example.app", jsonParams(port = 18889, hostPort = 18000))
        assertEquals(
            listOf(18000 to 18888, 18000 to 18889), device.forwarded,
            "re-pointing the host port at another device port must re-forward"
        )
    }

    @Test
    fun cleanupStillRemovesEveryRecordedForwardOnce() {
        val device = ForwardCountingDevice()
        val params = jsonParams(port = 18888)
        runtimeClientFor(device, "com.example.app", params)
        runtimeClientFor(device, "com.example.app", params)
        ForwardRegistry.cleanup()
        assertEquals(listOf(18888), device.removed)
    }

    @Test
    fun aStaleRegistryEntrySelfHealsOnARefusedConnection() {
        val port = closedPort()
        val device = ForwardCountingDevice()
        // The registry claims the forward is up, but nothing listens on the host
        // port — the shape of a forward killed externally mid-session.
        ForwardRegistry.record(device, hostPort = port, devicePort = port)
        val client = runtimeClientFor(device, "com.example.app", jsonParams(port = port))
        assertEquals(emptyList(), device.forwarded, "precondition: the cache hit skipped the forward")

        val health = client.probe(timeoutMillis = 2000)

        // The refused connect re-ran setUpForward once before retrying; with the
        // fake adb the port still refuses, so the classification is unchanged.
        assertEquals(listOf(port to port), device.forwarded, "the forward must be re-established once")
        assertIs<RuntimeHealth.Unreachable>(health)
    }

    @Test
    fun theForwardIsReestablishedAtMostOncePerClient() {
        val port = closedPort()
        val device = ForwardCountingDevice()
        ForwardRegistry.record(device, hostPort = port, devicePort = port)
        val client = runtimeClientFor(device, "com.example.app", jsonParams(port = port))
        repeat(3) { assertIs<RuntimeHealth.Unreachable>(client.probe(timeoutMillis = 2000)) }
        assertEquals(
            1, device.forwarded.size,
            "an agent that is simply down must not turn every poll into an adb fork"
        )
    }

    private fun jsonParams(port: Int, hostPort: Int? = null) = buildJsonObject {
        put("port", port)
        hostPort?.let { put("hostPort", it) }
    }
}
