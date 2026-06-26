package dev.reticle.cli.platform.android

import dev.reticle.cli.platform.CommandResult
import dev.reticle.cli.platform.DeviceController
import dev.reticle.cli.platform.DeviceError
import dev.reticle.cli.platform.DeviceState
import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit

/**
 * Android [DeviceController]: a thin wrapper around the `adb` executable. Device
 * selection, port forwarding, input dispatch, and screencap all go through adb.
 */
class Adb(
    private val adbPath: String = resolveAdbPath(),
    private val serial: String? = null,
) : DeviceController {

    override fun run(vararg args: String, timeoutSeconds: Long): CommandResult {
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
            return CommandResult(124, out.toString(Charsets.UTF_8), "adb timed out after ${timeoutSeconds}s")
        }
        outThread.join(1000)
        errThread.join(1000)
        return CommandResult(process.exitValue(), out.toString(Charsets.UTF_8), err.toString(Charsets.UTF_8))
    }

    /** Raw bytes variant for binary output like screencap PNG. */
    override fun runBytes(vararg args: String, timeoutSeconds: Long): ByteArray {
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

    override fun shell(command: String, timeoutSeconds: Long): CommandResult =
        run("shell", command, timeoutSeconds = timeoutSeconds)

    /** Forward a host TCP port to a device TCP port. Returns the host port. */
    override fun forward(hostPort: Int, devicePort: Int): CommandResult =
        run("forward", "tcp:$hostPort", "tcp:$devicePort")

    /**
     * Forward a host TCP port to a debuggable process's JDWP channel. This is the
     * root-free code-injection channel: every debuggable app exposes JDWP (even on
     * a `user` build where `wrap.<pkg>` is blocked). Reached over the same host
     * loopback as a TCP forward, but the device side is `jdwp:<pid>`.
     */
    override fun forwardJdwp(hostPort: Int, pid: Int): CommandResult =
        run("forward", "tcp:$hostPort", "jdwp:$pid")

    override fun removeForward(hostPort: Int): CommandResult =
        run("forward", "--remove", "tcp:$hostPort")

    /**
     * Run [args] as the app uid via `run-as <pkg>`. Only works for debuggable
     * apps, and is how we stage a payload into a private data dir without root.
     * Passes each arg separately (no nested `sh -c`) to avoid double-shell quoting
     * surprises with paths.
     */
    override fun runAs(packageName: String, vararg args: String, timeoutSeconds: Long): CommandResult =
        run("shell", "run-as", packageName, *args, timeoutSeconds = timeoutSeconds)

    override fun listDevices(): List<String> = listDeviceStates()
        .filter { it.state == "device" }
        .map { it.serial }

    /**
     * Every attached device with its raw adb state (`device`, `offline`,
     * `unauthorized`, …). Unlike [listDevices] this keeps non-ready devices so
     * callers can explain *why* a device can't be driven (e.g. the `offline`
     * state that needs a USB re-plug) instead of just reporting "no devices".
     */
    override fun listDeviceStates(): List<DeviceState> {
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
    override fun pidOf(packageName: String): Int? {
        val result = shell("pidof $packageName", timeoutSeconds = 10)
        if (!result.ok) return null
        return result.stdout.trim().split(Regex("\\s+")).firstOrNull()?.toIntOrNull()
    }

    /** Raw bytes of a device screenshot via `adb exec-out screencap -p`. */
    override fun screencap(timeoutSeconds: Long): ByteArray =
        runBytes("exec-out", "screencap", "-p", timeoutSeconds = timeoutSeconds)

    /**
     * State of this controller's device — `device`, `offline`, etc., or null if
     * absent. With a serial, look that device up. WITHOUT a serial, there must be
     * exactly one device: zero -> null (absent), one -> its state, but MANY is
     * ambiguous and throws [DeviceError] naming the candidates — far clearer than
     * the old `singleOrNull()` that silently returned null and surfaced as a
     * misleading "no device detected" whenever a stray emulator was attached.
     */
    override fun deviceState(): String? {
        val states = listDeviceStates()
        if (serial != null) return states.firstOrNull { it.serial == serial }?.state
        return when (states.size) {
            0 -> null
            1 -> states.first().state
            else -> throw DeviceError(
                "${states.size} devices/emulators attached; pick one with `--serial <id>`" +
                    " (or export ANDROID_SERIAL):\n" +
                    states.joinToString("\n") { "  ${it.serial}  [${it.state}]" }
            )
        }
    }

    /**
     * Make sure the target device is in the drivable `device` state before we
     * fire commands at it. `offline` (the state a flaky USB link or an adb
     * server restart leaves behind) accepts no shell/forward traffic, so without
     * this commands would just hang to their timeout. We try a bounded
     * `adb reconnect` recovery before giving up with an actionable message.
     */
    override fun ensureDeviceReady(retries: Int) {
        repeat(retries + 1) { attempt ->
            val last = attempt == retries
            when (val state = deviceState()) {
                "device" -> return
                null -> throw DeviceError(
                    "no device/emulator detected. Connect one (`adb devices` to check)."
                )
                "offline" -> {
                    if (last) throw DeviceError(
                        "device is OFFLINE and did not recover. Re-plug USB, or run `adb reconnect`," +
                            " then retry. (A flaky cable/port is the usual cause.)"
                    )
                    // Nudge the connection; offline often clears after a reconnect.
                    if (serial != null) run("reconnect", timeoutSeconds = 10)
                    else run("reconnect", "offline", timeoutSeconds = 10)
                    Thread.sleep(1500)
                }
                "unauthorized" -> throw DeviceError(
                    "device is UNAUTHORIZED. Accept the 'Allow USB debugging' prompt on the device" +
                        " (and check 'always allow'), then retry."
                )
                else -> if (last) throw DeviceError("device in state '$state'; cannot drive it.")
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
    override fun agentLog(maxLines: Int): List<String> {
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
