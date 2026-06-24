package dev.reticle.cli

import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit

/**
 * Thin wrapper around the `adb` executable: device selection, port forwarding,
 * input dispatch, and screencap all go through adb.
 */
class Adb(
    private val adbPath: String = resolveAdbPath(),
    private val serial: String? = null,
) {

    data class Result(val exitCode: Int, val stdout: String, val stderr: String) {
        val ok: Boolean get() = exitCode == 0
    }

    fun run(vararg args: String, timeoutSeconds: Long = 30): Result {
        val command = buildList {
            add(adbPath)
            if (serial != null) {
                add("-s"); add(serial)
            }
            addAll(args)
        }
        val process = ProcessBuilder(command).redirectErrorStream(false).start()
        val out = ByteArrayOutputStream()
        val err = ByteArrayOutputStream()
        val outThread = Thread { process.inputStream.copyTo(out) }.apply { start() }
        val errThread = Thread { process.errorStream.copyTo(err) }.apply { start() }
        if (!process.waitFor(timeoutSeconds, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            return Result(124, out.toString(Charsets.UTF_8), "adb timed out after ${timeoutSeconds}s")
        }
        outThread.join(1000)
        errThread.join(1000)
        return Result(process.exitValue(), out.toString(Charsets.UTF_8), err.toString(Charsets.UTF_8))
    }

    /** Raw bytes variant for binary output like screencap PNG. */
    fun runBytes(vararg args: String, timeoutSeconds: Long = 30): ByteArray {
        val command = buildList {
            add(adbPath)
            if (serial != null) {
                add("-s"); add(serial)
            }
            addAll(args)
        }
        val process = ProcessBuilder(command).start()
        val out = ByteArrayOutputStream()
        val outThread = Thread { process.inputStream.copyTo(out) }.apply { start() }
        process.errorStream.readBytes()
        if (!process.waitFor(timeoutSeconds, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            return ByteArray(0)
        }
        outThread.join(1000)
        return out.toByteArray()
    }

    fun shell(command: String, timeoutSeconds: Long = 30): Result =
        run("shell", command, timeoutSeconds = timeoutSeconds)

    /** Forward a host TCP port to a device TCP port. Returns the host port. */
    fun forward(hostPort: Int, devicePort: Int): Result =
        run("forward", "tcp:$hostPort", "tcp:$devicePort")

    fun removeForward(hostPort: Int): Result =
        run("forward", "--remove", "tcp:$hostPort")

    fun listDevices(): List<String> = listDeviceStates()
        .filter { it.state == "device" }
        .map { it.serial }

    data class DeviceState(val serial: String, val state: String)

    /**
     * Every attached device with its raw adb state (`device`, `offline`,
     * `unauthorized`, …). Unlike [listDevices] this keeps non-ready devices so
     * callers can explain *why* a device can't be driven (e.g. the `offline`
     * state that needs a USB re-plug) instead of just reporting "no devices".
     */
    fun listDeviceStates(): List<DeviceState> {
        val result = run("devices")
        return result.stdout.lineSequence()
            .drop(1)
            .mapNotNull { line ->
                val trimmed = line.trim()
                if (trimmed.isEmpty() || trimmed.startsWith("*")) return@mapNotNull null
                val parts = trimmed.split(Regex("\\s+"))
                if (parts.size >= 2) DeviceState(parts[0], parts[1]) else null
            }
            .toList()
    }

    /**
     * The PID of [packageName] on the device, or null if it isn't running.
     * Used by `status` to tell "agent not linked" apart from "app not running".
     */
    fun pidOf(packageName: String): Int? {
        val result = shell("pidof $packageName", timeoutSeconds = 10)
        if (!result.ok) return null
        return result.stdout.trim().split(Regex("\\s+")).firstOrNull()?.toIntOrNull()
    }

    /** Raw bytes of a device screenshot via `adb exec-out screencap -p`. */
    fun screencap(timeoutSeconds: Long = 20): ByteArray =
        runBytes("exec-out", "screencap", "-p", timeoutSeconds = timeoutSeconds)

    /** State of [serial] (or this Adb's serial) — `device`, `offline`, etc., or null if absent. */
    fun deviceState(serial: String? = this.serial): String? {
        val states = listDeviceStates()
        return if (serial != null) states.firstOrNull { it.serial == serial }?.state
        else states.singleOrNull()?.state
    }

    /**
     * Make sure the target device is in the drivable `device` state before we
     * fire commands at it. `offline` (the state a flaky USB link or an adb
     * server restart leaves behind) accepts no shell/forward traffic, so without
     * this commands would just hang to their timeout. We try a bounded
     * `adb reconnect` recovery before giving up with an actionable message.
     */
    fun ensureDeviceReady(retries: Int = 3) {
        repeat(retries + 1) { attempt ->
            val last = attempt == retries
            when (val state = deviceState()) {
                "device" -> return
                null -> throw AdbDeviceError(
                    "no device/emulator detected. Connect one (`adb devices` to check)."
                )
                "offline" -> {
                    if (last) throw AdbDeviceError(
                        "device is OFFLINE and did not recover. Re-plug USB, or run `adb reconnect`," +
                            " then retry. (A flaky cable/port is the usual cause.)"
                    )
                    // Nudge the connection; offline often clears after a reconnect.
                    if (serial != null) run("reconnect", timeoutSeconds = 10)
                    else run("reconnect", "offline", timeoutSeconds = 10)
                    Thread.sleep(1500)
                }
                "unauthorized" -> throw AdbDeviceError(
                    "device is UNAUTHORIZED. Accept the 'Allow USB debugging' prompt on the device" +
                        " (and check 'always allow'), then retry."
                )
                else -> if (last) throw AdbDeviceError("device in state '$state'; cannot drive it.")
            }
        }
    }

    /**
     * The agent's own logcat lines (tag `Reticle`). The agent logs a "started …"
     * line on a successful bind and a "FAILED to bind …" line on EADDRINUSE, so
     * these lines distinguish "agent not linked at all" (no Reticle lines) from
     * "linked but couldn't bind its port" (a FAILED line) — a split the network
     * probe alone can't make. `-d` dumps and exits; non-blocking.
     */
    fun reticleLogcat(maxLines: Int = 40): List<String> {
        val result = run("logcat", "-d", "-v", "brief", "-t", "2000", "-s", LOG_TAG, timeoutSeconds = 15)
        if (!result.ok) return emptyList()
        return result.stdout.lineSequence()
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("---------") }
            .toList()
            .takeLast(maxLines)
    }

    companion object {
        /** The logcat tag the in-app agent uses for its own lifecycle lines. */
        const val LOG_TAG = "Reticle"

        fun resolveAdbPath(): String {
            System.getenv("RETICLE_ADB")?.let { if (it.isNotBlank()) return it }
            val sdk = System.getenv("ANDROID_HOME") ?: System.getenv("ANDROID_SDK_ROOT")
            if (sdk != null) {
                val candidate = "$sdk/platform-tools/adb"
                if (java.io.File(candidate).canExecute()) return candidate
            }
            val home = System.getenv("HOME")
            if (home != null) {
                val candidate = "$home/Library/Android/sdk/platform-tools/adb"
                if (java.io.File(candidate).canExecute()) return candidate
            }
            return "adb" // rely on PATH
        }
    }
}

/** A device-readiness problem (offline / unauthorized / absent) with an actionable message. */
class AdbDeviceError(message: String) : RuntimeException(message)
