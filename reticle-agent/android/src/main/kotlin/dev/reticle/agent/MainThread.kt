package dev.reticle.agent

import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** The logcat tag the in-app agent uses for all of its lifecycle lines. */
internal const val RETICLE_LOG_TAG = "Reticle"

/**
 * Run [block] on the main (UI) thread and return its result, or null if the
 * work didn't finish within [timeoutSeconds]. Exceptions thrown by [block] are
 * swallowed (the caller gets null). Runs [block] directly when already on the
 * main thread. Shared by the mutation/screenshot/clipboard paths, which all
 * need the same "post, wait, best-effort" behavior; snapshot capture uses its
 * own stricter variant that propagates capture errors.
 */
internal fun <T> runOnMainSync(handler: Handler, timeoutSeconds: Long = 5, block: () -> T): T? {
    if (Looper.myLooper() == Looper.getMainLooper()) return swallowing(block)
    var result: T? = null
    val latch = CountDownLatch(1)
    handler.post {
        try {
            result = swallowing(block)
        } finally {
            latch.countDown()
        }
    }
    return if (latch.await(timeoutSeconds, TimeUnit.SECONDS)) result else null
}

/**
 * The swallow promised above. Without it, a throw inside the posted Runnable
 * would propagate to [Looper.loop] and kill the HOST app's main thread — a
 * debugging request must never be able to crash the process it is observing
 * (a screenshot's Bitmap allocation can OOM, a text mutation can trip an
 * app-registered TextWatcher).
 */
private fun <T> swallowing(block: () -> T): T? = try {
    block()
} catch (t: Throwable) {
    Log.w(RETICLE_LOG_TAG, "main-thread work failed; returning null", t)
    null
}
