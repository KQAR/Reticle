package dev.reticle.cli.platform

/**
 * Controls a single device/emulator and the host<->device transport.
 *
 * This is an **internal seam of the Android helper**, not a multi-platform SPI.
 * Platform selection happens one level up, in the Swift host (`--target`), and by
 * the recorded decision a helper exists only where a platform's dirty-work lives
 * outside the host's ecosystem — Android (JDWP/adb) does, iOS does not. So the
 * only implementation is [dev.reticle.cli.platform.android.Adb] and the method
 * names keep their adb-isms (`shell`, `run`, `runAs`) on purpose: naming them
 * generically would advertise a portability this interface does not have.
 *
 * Construct one through `Adb.forSerial(serial)`, the helper's single
 * device-construction point.
 */
interface DeviceController {
    /**
     * The device serial this controller is bound to, or null for the
     * single-attached-device default. Used as an identity key (e.g. by the
     * forward registry): two controllers with the same serial drive the same
     * device even when they are distinct instances.
     */
    val serialOrNull: String?

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

/** Result of a host->device command: exit code + captured streams. */
data class CommandResult(val exitCode: Int, val stdout: String, val stderr: String) {
    val ok: Boolean get() = exitCode == 0
}

/** An attached device and its raw readiness state ("device"/"offline"/...). */
data class DeviceState(val serial: String, val state: String)

/** A device-readiness problem (offline / unauthorized / absent), with guidance. */
class DeviceError(message: String) : RuntimeException(message)
