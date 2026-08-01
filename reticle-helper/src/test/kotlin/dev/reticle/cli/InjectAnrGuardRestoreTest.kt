package dev.reticle.cli

import dev.reticle.cli.platform.CommandResult
import dev.reticle.cli.platform.DeviceController
import dev.reticle.cli.platform.DeviceState
import dev.reticle.cli.platform.android.InjectAnrGuard
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Restore semantics of [InjectAnrGuard.install], driven by what `debug_app`
 * said BEFORE the guard ran. Three cases, three different undos:
 *
 *  - nothing was marked      -> restore clears the marking;
 *  - another app was marked  -> restore puts that app back;
 *  - the TARGET was marked   -> the developer set it themselves; the marking
 *    predates us and must outlive us, so restore is a no-op. The regression
 *    pinned here: `previous?.takeIf { it != packageName }` folded this case
 *    into "nothing was marked" and restore then destroyed the user's marking
 *    with `am clear-debug-app`.
 */
class InjectAnrGuardRestoreTest {

    /** Answers the guard's `debug_app` read with a canned value, records shells. */
    private class MarkedDevice(private val debugApp: String) : DeviceController {
        val shellCommands = mutableListOf<String>()

        override fun shell(command: String, timeoutSeconds: Long): CommandResult {
            shellCommands.add(command)
            if (command.startsWith("settings get global debug_app")) {
                return CommandResult(0, "$debugApp\n", "")
            }
            return CommandResult(0, "", "")
        }

        override fun run(vararg args: String, timeoutSeconds: Long) = CommandResult(0, "", "")
        override fun runBytes(vararg args: String, timeoutSeconds: Long) = ByteArray(0)
        override fun forward(hostPort: Int, devicePort: Int) = CommandResult(0, "", "")
        override fun forwardJdwp(hostPort: Int, pid: Int) = CommandResult(0, "", "")
        override fun removeForward(hostPort: Int) = CommandResult(0, "", "")
        override fun runAs(packageName: String, vararg args: String, timeoutSeconds: Long) =
            CommandResult(0, "", "")
        override fun listDevices() = listOf("test-serial")
        override fun listDeviceStates() = listOf(DeviceState("test-serial", "device"))
        override val serialOrNull: String? = "test-serial"
        override fun pidOf(packageName: String): Int? = null
        override fun screencap(timeoutSeconds: Long) = ByteArray(0)
        override fun deviceState(): String? = "device"
        override fun ensureDeviceReady(retries: Int) {}
        override fun agentLog(maxLines: Int) = emptyList<String>()
    }

    @Test
    fun restoreClearsWhenNothingWasMarked() {
        val device = MarkedDevice(debugApp = "null")
        InjectAnrGuard.install(device, "com.example.app").restore()
        assertTrue(
            device.shellCommands.any { it.startsWith("am clear-debug-app") },
            "an install over an unset marking must clear on restore; saw ${device.shellCommands}"
        )
    }

    @Test
    fun restorePutsBackAnotherAppsMarking() {
        val device = MarkedDevice(debugApp = "com.example.other")
        InjectAnrGuard.install(device, "com.example.app").restore()
        assertTrue(
            device.shellCommands.any { it == "am set-debug-app --persistent com.example.other" },
            "the previously marked app must be restored; saw ${device.shellCommands}"
        )
        assertFalse(
            device.shellCommands.any { it.startsWith("am clear-debug-app") },
            "restoring another app's marking must not clear; saw ${device.shellCommands}"
        )
    }

    @Test
    fun restoreLeavesAPreexistingMarkingOfTheTargetAlone() {
        val device = MarkedDevice(debugApp = "com.example.app")
        val installed = InjectAnrGuard.install(device, "com.example.app")
        assertTrue(installed.active, "precondition: the marking took, so the guard is active")
        val before = device.shellCommands.toList()
        installed.restore()
        assertTrue(
            device.shellCommands == before,
            "the user's own marking predates the guard and must survive restore;" +
                " saw ${device.shellCommands.drop(before.size)}"
        )
    }
}
