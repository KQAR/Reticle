package dev.reticle.agent

import android.webkit.WebView
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Whether a sealed iframe can be read in its own context — and, when it cannot,
 * WHICH half is missing.
 *
 * androidx.webkit is not a dependency of the agent at any scope, not even
 * `compileOnly` (see the note in `build.gradle.kts`): the per-frame read reaches it
 * purely by reflection so the AAR links identically into an app that ships it and
 * one that does not, and so the injected payload dex carries no support library that
 * could collide with the host's own copy.
 *
 * That makes this suite's classpath the REAL no-library configuration rather than a
 * simulated one — the same shape an app without the dependency sees on a device.
 *
 * The three answers are separate on purpose. They were one boolean first, and a
 * boolean cannot tell an app that needs a dependency from a device that needs a
 * newer WebView from a Reticle bug — `docs/boundaries.md` states each as its own
 * marker (`iframe:probe-unavailable` + `custom.domFrameProbeDetail`) precisely
 * because they demand different moves: ship the library, update WebView, or file
 * this as a defect.
 */
@RunWith(RobolectricTestRunner::class)
class WebFrameBridgeAvailabilityTest {

    private val context = RuntimeEnvironment.getApplication()

    @Test
    fun withoutTheSupportLibraryTheReasonNamesTheLibrary() {
        // Not "unavailable", not false: the caller has to be able to tell that adding
        // a dependency lifts this, which is the only one of the three walls an app's
        // own code can lift.
        assertEquals("no-library", WebFrameBridge.unavailableReason())
    }

    @Test
    fun availabilityIsExactlyTheAbsenceOfAReason() {
        // `isAvailable()` is a projection of `unavailableReason()`, so the two can
        // never disagree about the same build — which is what let an earlier boolean
        // report "unavailable" while the detail said the library was present.
        assertEquals(WebFrameBridge.unavailableReason() == null, WebFrameBridge.isAvailable())
        assertFalse(WebFrameBridge.isAvailable())
    }

    @Test
    fun installRefusesQuietlyWhenTheLibraryIsAbsent() {
        // It runs during capture, inside the app under test, on its UI thread. A
        // missing optional dependency must cost `false`, never an exception — an
        // agent that throws here takes the whole snapshot with it.
        assertFalse(WebFrameBridge.install(WebView(context)))
    }

    @Test
    fun theReasonIsStableAcrossCallsSoAMarkerDoesNotFlicker() {
        // The value is read once per frame per capture and lands in the snapshot as
        // `custom.domFrameProbeDetail`; two captures of one screen disagreeing about
        // it would read as the device changing under the caller.
        val reasons = (1..5).map { WebFrameBridge.unavailableReason() }

        assertEquals(1, reasons.distinct().size, "reasons: $reasons")
        assertTrue(reasons.all { it == "no-library" })
    }
}
