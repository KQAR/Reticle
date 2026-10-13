package dev.reticle.cli

import dev.reticle.cli.platform.android.Adb
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * [Adb.forward] must never take a host port another device's forward holds —
 * plain `adb forward` rebinds silently — while still accepting a mapping this
 * serial already owns (a restarted helper finds its old forward on the adb server).
 * A fake adb records its argv and answers `forward` the way the real one does
 * under `--no-rebind`: it fails whenever the host port is already in the list.
 */
class AdbForwardTest {

    private val files = mutableListOf<File>()

    @AfterTest
    fun cleanup() = files.forEach { it.delete() }

    private fun temp(suffix: String) = File.createTempFile("fake-adb", suffix).also { files.add(it) }

    /** [existing] is the `adb forward --list` output, one `serial tcp:H tcp:D` per line. */
    private fun fakeAdb(existing: String): Pair<String, File> {
        val list = temp(".list").apply { writeText(existing) }
        val log = temp(".log")
        val script = temp(".sh").apply {
            setExecutable(true)
            writeText(
                "#!/bin/sh\n" +
                    "echo \"$*\" >> ${log.absolutePath}\n" +
                    "if [ \"$1\" = \"-s\" ]; then shift 2; fi\n" +
                    "if [ \"$1 $2\" = \"forward --list\" ]; then cat ${list.absolutePath}; exit 0; fi\n" +
                    "if [ \"$1 $2\" = \"forward --no-rebind\" ]; then\n" +
                    "  if grep -q \" $3 \" ${list.absolutePath}; then echo 'cannot rebind existing socket' >&2; exit 1; fi\n" +
                    "  exit 0\n" +
                    "fi\n" +
                    "exit 0\n"
            )
        }
        return script.absolutePath to log
    }

    @Test
    fun aFreshForwardIsRequestedWithNoRebind() {
        val (adb, log) = fakeAdb("")
        assertTrue(Adb(adbPath = adb, serial = "device-a").forward(18900, 8800).ok)
        assertEquals("-s device-a forward --no-rebind tcp:18900 tcp:8800", log.readLines().first())
    }

    @Test
    fun aForwardThisSerialAlreadyOwnsIsAccepted() {
        val (adb, _) = fakeAdb("device-a tcp:18900 tcp:8800\n")
        assertTrue(Adb(adbPath = adb, serial = "device-a").forward(18900, 8800).ok)
    }

    @Test
    fun anotherDevicesForwardIsRefusedNotStolen() {
        val (adb, log) = fakeAdb("device-b tcp:18900 tcp:8800\n")
        val result = Adb(adbPath = adb, serial = "device-a").forward(18900, 8800)
        assertFalse(result.ok)
        assertTrue(result.stderr.contains("18900") && result.stderr.contains("device-b"), result.stderr)
        assertTrue(log.readLines().none { it.endsWith("forward tcp:18900 tcp:8800") }, "must never fall back to a rebinding forward")
    }
}
