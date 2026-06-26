package dev.reticle.agent

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Handler
import android.os.Looper
import android.view.View
import java.io.ByteArrayOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * In-process screenshot. Renders the attached window roots into a bitmap on the
 * main thread.
 *
 * Note: the host CLI also exposes `adb exec-out screencap` as a fallback that
 * works without the agent — this in-process path serves pixels from inside the
 * app so the same loopback contract holds. SurfaceViews / secure windows won't
 * be captured here; that's the documented boundary.
 */
class ScreenshotCapture(private val context: Context) {

    private val handler = Handler(Looper.getMainLooper())

    fun capturePng(): ByteArray? {
        val bitmap = runOnMainSync { renderTopWindow() } ?: return null
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
        return stream.toByteArray()
    }

    private fun renderTopWindow(): Bitmap? {
        val roots = ReticleWindows.rootViews()
        val target: View = roots.lastOrNull { it.width > 0 && it.height > 0 } ?: return null
        val bitmap = Bitmap.createBitmap(target.width, target.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        target.draw(canvas)
        return bitmap
    }

    private fun <T> runOnMainSync(block: () -> T): T? {
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
        return if (latch.await(5, TimeUnit.SECONDS)) result else null
    }
}
