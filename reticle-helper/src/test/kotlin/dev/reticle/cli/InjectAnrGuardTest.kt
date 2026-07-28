package dev.reticle.cli

import dev.reticle.cli.platform.android.InjectAnrGuard
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Tests for the parsing halves of [InjectAnrGuard] — the two device readings the
 * ANR guard depends on. Both are pure string work on real device output, so they
 * are checkable without a device; the orchestration around them (set-debug-app /
 * restore) is device I/O and stays out of scope here.
 */
class InjectAnrGuardTest {

    // --- debug_app ---------------------------------------------------------

    @Test
    fun parseDebugApp_readsAnExistingMarking() {
        // `settings get global debug_app` prints the bare package plus a newline.
        assertEquals("com.example.other", InjectAnrGuard.parseDebugApp("com.example.other\n"))
    }

    @Test
    fun parseDebugApp_treatsTheLiteralNullAsUnset() {
        // The common case: nothing is marked, and restoring must then CLEAR rather
        // than set a package literally named "null".
        assertNull(InjectAnrGuard.parseDebugApp("null\n"))
    }

    @Test
    fun parseDebugApp_isNullWhenTheSettingCannotBeRead() {
        // An empty answer, or an error sentence, must never be mistaken for a
        // package name that then gets "restored" onto the device.
        assertNull(InjectAnrGuard.parseDebugApp(""))
        assertNull(InjectAnrGuard.parseDebugApp("   \n"))
        assertNull(InjectAnrGuard.parseDebugApp("cmd: Can't find service: settings"))
    }

    // --- exit-info ---------------------------------------------------------

    private val anrExitInfo = """
        package: com.example.app
          Historical Process Exit for uid=10234
            ApplicationExitInfo(timestamp=2026-07-27 10:12:03.114 pid=9312 realUid=10234 reason=6 (ANR) subreason=0 (UNKNOWN) status=0 importance=100 description=Input dispatching timed out (com.example.app/.MainActivity (server) is not responding. Waited 5000ms for MotionEvent(deviceId=-1, action=DOWN)))
            ApplicationExitInfo(timestamp=2026-07-27 09:58:41.002 pid=8871 realUid=10234 reason=10 (USER REQUESTED) subreason=0 (UNKNOWN) status=0 importance=400 description=stop com.example.app due to from pid 2110)
    """.trimIndent()

    @Test
    fun anrExit_namesTheInputDispatchTimeout() {
        val described = InjectAnrGuard.anrExit(anrExitInfo, attachedPid = 9312)
        assertTrue(described!!.startsWith("Input dispatching timed out"), described)
        assertTrue(described.contains("Waited 5000ms"), described)
    }

    @Test
    fun anrExit_ignoresNonAnrExits() {
        // A user-requested stop is not an ANR: claiming it was would send the
        // caller after a timeout that never happened.
        val userStopOnly = anrExitInfo.lines().filterNot { it.contains("reason=6") }.joinToString("\n")
        assertNull(InjectAnrGuard.anrExit(userStopOnly, attachedPid = 8871))
    }

    @Test
    fun anrExit_isNullWhenExitInfoIsUnavailable() {
        // Pre-Android-11 devices have no exit-info service at all. No evidence,
        // no verdict — the original error must survive.
        assertNull(InjectAnrGuard.anrExit(""))
        assertNull(InjectAnrGuard.anrExit("Unknown command: exit-info"))
    }

    @Test
    fun anrExit_fallsBackToTheFirstAnrWhenThePidDoesNotMatch() {
        // The pid we attached to may predate the records kept; an ANR record that
        // is there is still the best evidence available.
        val described = InjectAnrGuard.anrExit(anrExitInfo, attachedPid = 1)
        assertTrue(described!!.contains("Input dispatching timed out"), described)
    }

    @Test
    fun anrExit_describesAnAnrRecordWithNoDescriptionField() {
        val terse = "ApplicationExitInfo(pid=42 reason=6 (ANR) subreason=0 (UNKNOWN))"
        val described = InjectAnrGuard.anrExit(terse, attachedPid = 42)
        assertTrue(described!!.contains("main thread was suspended"), described)
    }
}
