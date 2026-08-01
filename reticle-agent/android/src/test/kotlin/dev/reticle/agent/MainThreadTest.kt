package dev.reticle.agent

import android.os.Handler
import android.os.Looper
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.util.concurrent.Executors
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * The "best-effort" contract of [runOnMainSync]: a throw inside [block] must be
 * swallowed into a null result, never propagated. The posted path is the one
 * that matters — an uncaught throw there would reach [Looper.loop] and crash
 * the HOST app's main thread, turning a debugging request (screenshot OOM, a
 * text mutation tripping an app TextWatcher) into a process kill.
 */
@RunWith(RobolectricTestRunner::class)
class MainThreadTest {

    private val handler = Handler(Looper.getMainLooper())

    @Test
    fun returnsTheBlockResultWhenAlreadyOnMain() {
        assertEquals(42, runOnMainSync(handler) { 42 })
    }

    @Test
    fun aThrowOnTheDirectMainThreadPathBecomesNull() {
        assertNull(runOnMainSync(handler) { error("boom") })
    }

    @Test
    fun aThrowInsideThePostedRunnableBecomesNullInsteadOfKillingTheLooper() {
        val executor = Executors.newSingleThreadExecutor()
        try {
            val call = executor.submit<Int?> {
                runOnMainSync(handler) { error("boom") }
            }
            // The background caller parks on the latch; keep draining the main
            // looper until its posted work has run.
            while (!call.isDone) {
                shadowOf(Looper.getMainLooper()).idle()
                Thread.sleep(5)
            }
            assertNull(call.get())
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun thePostedPathStillDeliversAResult() {
        val executor = Executors.newSingleThreadExecutor()
        try {
            val call = executor.submit<Int?> {
                runOnMainSync(handler) { 7 }
            }
            while (!call.isDone) {
                shadowOf(Looper.getMainLooper()).idle()
                Thread.sleep(5)
            }
            assertEquals(7, call.get())
        } finally {
            executor.shutdownNow()
        }
    }
}
