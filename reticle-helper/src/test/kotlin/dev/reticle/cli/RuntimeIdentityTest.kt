package dev.reticle.cli

import dev.reticle.cli.platform.CommandResult
import dev.reticle.cli.platform.DeviceController
import dev.reticle.cli.platform.DeviceState
import dev.reticle.core.RuntimeInfo
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Tests for [RuntimeIdentity]: the runtime that answered a forward must be the
 * process running on the targeted device, not the same package on another one.
 */
class RuntimeIdentityTest {

    /** Answers `pidof` with [pid] and counts how often it was asked. */
    private class PidDevice(override val serialOrNull: String?, var pid: Int?) : DeviceController {
        var pidofCalls = 0
        override fun pidOf(packageName: String): Int? { pidofCalls++; return pid }
        override fun forward(hostPort: Int, devicePort: Int) = CommandResult(0, "", "")
        override fun removeForward(hostPort: Int) = CommandResult(0, "", "")
        override fun run(vararg args: String, timeoutSeconds: Long) = CommandResult(0, "", "")
        override fun runBytes(vararg args: String, timeoutSeconds: Long) = ByteArray(0)
        override fun shell(command: String, timeoutSeconds: Long) = CommandResult(0, "", "")
        override fun forwardJdwp(hostPort: Int, pid: Int) = CommandResult(0, "", "")
        override fun runAs(packageName: String, vararg args: String, timeoutSeconds: Long) =
            CommandResult(0, "", "")
        override fun listDevices() = listOfNotNull(serialOrNull)
        override fun listDeviceStates() = listOfNotNull(serialOrNull).map { DeviceState(it, "device") }
        override fun screencap(timeoutSeconds: Long) = ByteArray(0)
        override fun deviceState(): String? = "device"
        override fun ensureDeviceReady(retries: Int) {}
        override fun agentLog(maxLines: Int) = emptyList<String>()
    }

    private fun info(pid: Int) = RuntimeInfo(
        packageName = "com.example.app", processName = "com.example.app",
        pid = pid, sdkInt = 35, agentVersion = "0", port = 18888,
    )

    @AfterTest
    fun tearDown() = RuntimeIdentity.clear()

    @Test
    fun theTargetDevicesOwnProcessPassesAndIsCached() {
        val device = PidDevice("A", pid = 42)
        assertNull(RuntimeIdentity.mismatch(device, 18888, info(42)))
        assertNull(RuntimeIdentity.mismatch(device, 18888, info(42)))
        assertEquals(1, device.pidofCalls, "a verified pid must not cost another adb call")
    }

    @Test
    fun anAnswerFromAnotherDeviceIsAConflictNamingBoth() {
        // The app runs on device A as pid 42; the forward reaches B's pid 77.
        val reason = assertNotNull(RuntimeIdentity.mismatch(PidDevice("A", pid = 42), 18888, info(77)))
        assertTrue("pid 77" in reason && "pid 42" in reason && "device A" in reason, reason)
    }

    @Test
    fun anAnswerWhileTheAppIsNotRunningHereIsAConflict() {
        val reason = assertNotNull(RuntimeIdentity.mismatch(PidDevice("A", pid = null), 18888, info(77)))
        assertTrue("not running" in reason, reason)
    }

    @Test
    fun aVerifiedForwardThatStartsAnsweringWithAnotherPidIsRechecked() {
        val device = PidDevice("A", pid = 42)
        assertNull(RuntimeIdentity.mismatch(device, 18888, info(42)))
        // Another session rebinds the host port to its device: the pid changes.
        assertNotNull(RuntimeIdentity.mismatch(device, 18888, info(77)))
        assertEquals(2, device.pidofCalls)
    }
}
