package dev.reticle.agent

import android.os.Handler
import android.os.Looper
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
    if (Looper.myLooper() == Looper.getMainLooper()) return block()
    var result: T? = null
    val latch = CountDownLatch(1)
    handler.post {
        try {
            result = block()
        } finally {
            latch.countDown()
        }
    }
    return if (latch.await(timeoutSeconds, TimeUnit.SECONDS)) result else null
}
