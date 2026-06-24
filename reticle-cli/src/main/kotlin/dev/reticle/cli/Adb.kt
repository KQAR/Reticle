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

    fun listDevices(): List<String> {
        val result = run("devices")
        return result.stdout.lineSequence()
            .drop(1)
            .mapNotNull { line ->
                val trimmed = line.trim()
                if (trimmed.isEmpty()) return@mapNotNull null
                val parts = trimmed.split(Regex("\\s+"))
                if (parts.size >= 2 && parts[1] == "device") parts[0] else null
            }
            .toList()
    }

    companion object {
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
