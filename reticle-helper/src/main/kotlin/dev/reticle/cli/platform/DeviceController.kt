package dev.reticle.cli.platform

/**
 * Controls a single device/emulator and the host<->device transport. Mirrors the
 * capability surface the CLI uses today; the Android implementation backs it with
 * `adb`. Method names still carry adb-isms (`shell`, `run`, `runAs`) because the
 * interface is extracted from the Android implementation — a second platform is
 * what will tell us which of these generalize and which are Android-only.
 */
interface DeviceController {
    /** Run a raw device tool subcommand (Android: `adb <args>`). */
    fun run(vararg args: String, timeoutSeconds: Long = 30): CommandResult

    /** Raw-bytes variant for binary output (Android: screencap PNG). */
    fun runBytes(vararg args: String, timeoutSeconds: Long = 30): ByteArray

    /** Run a device shell command line. */
    fun shell(command: String, timeoutSeconds: Long = 30): CommandResult

    /** Forward a host TCP port to a device TCP port. */
    fun forward(hostPort: Int, devicePort: Int): CommandResult

    /** Forward a host TCP port to a debuggable process's JDWP channel. */
    fun forwardJdwp(hostPort: Int, pid: Int): CommandResult

    /** Tear down a host TCP forward. */
    fun removeForward(hostPort: Int): CommandResult

    /** Run args as the app uid (Android: `run-as <pkg>`) — debuggable apps only. */
    fun runAs(packageName: String, vararg args: String, timeoutSeconds: Long = 30): CommandResult

    /** Ready (drivable) device serials. */
    fun listDevices(): List<String>

    /** Every attached device with its raw readiness state. */
    fun listDeviceStates(): List<DeviceState>

    /** PID of [packageName], or null if not running. */
    fun pidOf(packageName: String): Int?

    /** Raw bytes of a device screenshot. */
    fun screencap(timeoutSeconds: Long = 20): ByteArray

    /**
     * State of this controller's device ("device"/"offline"/...), or null if
     * absent. With no serial set and MULTIPLE devices attached, the target is
     * ambiguous and this throws [DeviceError] rather than guessing.
     */
    fun deviceState(): String?

    /** Ensure the device is in the drivable state, with bounded recovery; else throw [DeviceError]. */
    fun ensureDeviceReady(retries: Int = 3)

    /** The agent's own runtime log lines (Android: logcat tag `Reticle`). */
    fun agentLog(maxLines: Int = 40): List<String>
}
