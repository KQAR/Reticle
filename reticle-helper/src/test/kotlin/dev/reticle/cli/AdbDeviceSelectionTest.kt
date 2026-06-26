package dev.reticle.cli

import dev.reticle.cli.platform.DeviceError
import dev.reticle.cli.platform.android.Adb
import java.io.File
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Tests for [Adb.deviceState] device-target resolution — the multi-device
 * disambiguation. Uses a fake `adb` script whose `devices` output we control, so
 * no real device or adb is involved.
 */
class AdbDeviceSelectionTest {

    private val scripts = mutableListOf<File>()

    @AfterTest
    fun cleanup() = scripts.forEach { it.delete() }

    /**
     * A fake adb that prints the `adb devices` listing for [deviceLines] (each
     * "serial\tstate"), else nothing. The listing is written to a sibling data
     * file the script `cat`s — keeping device serials/states out of the shell
     * source entirely, so no quoting/indent fragility.
     */
    private fun fakeAdb(vararg deviceLines: String): String {
        val data = File.createTempFile("fake-adb-devices", ".txt").apply { scripts.add(this) }
        data.writeText(buildString {
            append("List of devices attached\n")
            deviceLines.forEach { append(it).append('\n') }
        })
        val f = File.createTempFile("fake-adb", ".sh").apply {
            setExecutable(true)
            scripts.add(this)
        }
        // No trimIndent / no interpolated device data — the shebang stays valid
        // and `adb devices` just cats the prepared listing. Skip a leading
        // `-s <serial>` the way real adb does (Adb.run prepends it), so `devices`
        // is still recognized when a serial is set.
        f.writeText(
            "#!/bin/sh\n" +
                "if [ \"$1\" = \"-s\" ]; then shift 2; fi\n" +
                "if [ \"$1\" = \"devices\" ]; then cat ${data.absolutePath}; fi\n" +
                "exit 0\n"
        )
        return f.absolutePath
    }

    @Test
    fun singleDevice_noSerial_returnsItsState() {
        val adb = Adb(adbPath = fakeAdb("O785AMVW9TIJTOKJ\tdevice"))
        assertEquals("device", adb.deviceState())
    }

    @Test
    fun noDevices_returnsNull() {
        val adb = Adb(adbPath = fakeAdb())
        assertNull(adb.deviceState())
    }

    @Test
    fun multipleDevices_noSerial_throwsWithCandidates() {
        val adb = Adb(adbPath = fakeAdb("O785AMVW9TIJTOKJ\tdevice", "emulator-5554\tdevice"))
        val e = assertFailsWith<DeviceError> { adb.deviceState() }
        assertTrue(e.message!!.contains("--serial"), "should tell the user to pass --serial")
        assertTrue(e.message!!.contains("O785AMVW9TIJTOKJ"), "should name the candidates")
        assertTrue(e.message!!.contains("emulator-5554"))
    }

    @Test
    fun multipleDevices_withSerial_selectsThatOne() {
        assertEquals("device", Adb(adbPath = fakeAdb("O785AMVW9TIJTOKJ\tdevice", "emulator-5554\toffline"), serial = "O785AMVW9TIJTOKJ").deviceState())
        assertEquals("offline", Adb(adbPath = fakeAdb("O785AMVW9TIJTOKJ\tdevice", "emulator-5554\toffline"), serial = "emulator-5554").deviceState())
    }

    @Test
    fun serialNotAttached_returnsNull() {
        val adb = Adb(adbPath = fakeAdb("O785AMVW9TIJTOKJ\tdevice"), serial = "nope")
        assertNull(adb.deviceState())
    }
}
