package dev.reticle.cli

import dev.reticle.cli.platform.CommandResult
import dev.reticle.cli.platform.DeviceController
import dev.reticle.cli.platform.DeviceState
import dev.reticle.cli.platform.android.Injector
import kotlin.test.Test
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * `--restart-under-debugger` marks the target as the persistent debug app, and
 * that marking MUST be undone on every exit path — a leaked marking outlives
 * the session, keeps force-stopping the target on later runs, and is invisible
 * until someone thinks to read `settings get global debug_app`. The regression
 * pinned here: the relaunch used to run OUTSIDE the try/finally that restores
 * the guard, so a relaunch failure leaked the marking.
 */
class InjectorGuardRestoreTest {

    /** Answers the guard's install/read calls, refuses the relaunch. */
    private class RelaunchRefusingDevice : DeviceController {
        val shellCommands = mutableListOf<String>()

        override fun shell(command: String, timeoutSeconds: Long): CommandResult {
            shellCommands.add(command)
            if (command.startsWith("monkey ")) throw CliError("monkey refused")
            if (command.startsWith("settings get global debug_app")) {
                return CommandResult(0, "null\n", "")
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
        override fun pidOf(packageName: String): Int? = null
        override fun screencap(timeoutSeconds: Long) = ByteArray(0)
        override fun deviceState(): String? = "device"
        override fun ensureDeviceReady(retries: Int) {}
        override fun agentLog(maxLines: Int) = emptyList<String>()
    }

    @Test
    fun aFailedRelaunchStillRestoresTheDebugAppMarking() {
        val device = RelaunchRefusingDevice()
        assertFailsWith<CliError> {
            Injector.inject(device, "com.example.app", restartUnderDebugger = true)
        }
        assertTrue(
            device.shellCommands.any { it.startsWith("am set-debug-app") },
            "precondition: the guard should have been installed; saw ${device.shellCommands}"
        )
        assertTrue(
            device.shellCommands.any { it.startsWith("am clear-debug-app") },
            "the marking must be restored even when the relaunch throws; saw ${device.shellCommands}"
        )
    }
}
