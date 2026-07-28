package dev.reticle.cli

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * [ToastQueue]: the one channel that can answer "what did the app say" when the
 * app said it with a `Toast`.
 *
 * Every fixture here is a verbatim line from `dumpsys notification` on an API 36
 * emulator, because this parser's whole job is to survive a format it does not
 * own — a hand-written approximation of the record would pin nothing.
 */
class ToastQueueTest {

    private val pkg = "dev.reticle.sample"

    private val textToast = """
        Toast Queue:
            TextToastRecord{f933a23 16368:dev.reticle.sample/u0a214 isSystemToast=false token=android.os.BinderProxy@7789b20 text=TOASTPROBE rejected by server duration=1}

        Notification List:
    """.trimIndent()

    private val customToast = """
        Toast Queue:
            CustomToastRecord{cdd2539 16485:dev.reticle.sample/u0a214 isSystemToast=false token=android.os.BinderProxy@e96677e callback=android.app.ITransientNotification${'$'}Stub${'$'}Proxy@fb3c1e5}
    """.trimIndent()

    @Test
    fun readsTheMessageOfATextToast() {
        val sighting = ToastQueue.parse(textToast, pkg).single()
        assertEquals(ToastQueue.KIND_TEXT, sighting.kind)
        assertEquals("TOASTPROBE rejected by server", sighting.text)
        assertEquals("long", sighting.duration)
        assertEquals(pkg, sighting.packageName)
        assertEquals("android.os.BinderProxy@7789b20", sighting.token)
    }

    @Test
    fun aCustomViewToastHasNoTextAndSaysSoRatherThanReportingEmpty() {
        // Measured: this record carries a callback into the app, not a string. The
        // text of such a toast IS reachable — as a node in the view tree, because
        // the app drew it — and conflating "no text here" with "no text anywhere"
        // is exactly the wrong claim.
        val sighting = ToastQueue.parse(customToast, pkg).single()
        assertEquals(ToastQueue.KIND_CUSTOM, sighting.kind)
        assertNull(sighting.text)
        assertTrue(ToastQueue.summary(sighting).contains("its text is a node in the tree"))
    }

    @Test
    fun aMessageContainingTheWordDurationSurvives() {
        // `text=` runs to the `duration=` that CLOSES the record, so the message is
        // read from the end. Reading to the first space, or to the first
        // `duration=`, cuts this one in half.
        val line = "  TextToastRecord{a1 1:$pkg/u0a1 isSystemToast=false token=t@1 " +
            "text=Session duration=30 days remaining duration=0}"
        val sighting = ToastQueue.parse(line, pkg).single()
        assertEquals("Session duration=30 days remaining", sighting.text)
        assertEquals("short", sighting.duration)
    }

    @Test
    fun anotherAppsToastIsNotThisActionsAnswer() {
        // The system's own "Screenshot saved" lands in the same queue. Attributing
        // it to the app under test would be a wrong claim, not a generous one.
        val other = textToast.replace(pkg, "com.android.systemui")
        assertTrue(ToastQueue.parse(other, pkg).isEmpty())
    }

    @Test
    fun anEmptyQueueIsNotAnError() {
        // The overwhelmingly common case: device-side `grep` matched nothing, so
        // the command's own output is empty and its exit code is 1.
        assertTrue(ToastQueue.parse("", pkg).isEmpty())
    }

    @Test
    fun theSameToastAcrossTwoSamplesIsOneSighting() {
        // A toast sits in the queue for its whole 2s/3.5s on screen, so the probe
        // sees it repeatedly; the binder token is what makes it one event.
        val first = ToastQueue.parse(textToast, pkg).single()
        val second = ToastQueue.parse(textToast, pkg).single()
        assertEquals(first.identity, second.identity)
    }

    @Test
    fun twoDifferentToastsWithTheSameTextStayTwo() {
        val twice = textToast + "\n" +
            "    TextToastRecord{b2 16368:$pkg/u0a214 isSystemToast=false " +
            "token=android.os.BinderProxy@dead01 text=TOASTPROBE rejected by server duration=1}"
        val ids = ToastQueue.parse(twice, pkg).map { it.identity }.toSet()
        assertEquals(2, ids.size)
    }

    @Test
    fun aSystemToastIsFlagged() {
        val system = textToast.replace("isSystemToast=false", "isSystemToast=true")
        assertTrue(ToastQueue.parse(system, pkg).single().isSystemToast)
    }
}
