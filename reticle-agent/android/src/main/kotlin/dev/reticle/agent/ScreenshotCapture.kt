package dev.reticle.agent

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Handler
import android.os.Looper
import java.io.ByteArrayOutputStream

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
        val bitmap = runOnMainSync(handler) { renderWindows() } ?: return null
        return try {
            val stream = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            stream.toByteArray()
        } finally {
            // Free the full-screen ARGB_8888 bitmap now instead of waiting for GC;
            // repeated screenshots otherwise build real peak-memory pressure.
            bitmap.recycle()
        }
    }

    /**
     * Composite every attached window bottom-to-top at its on-screen offset,
     * so a dialog renders over its host activity instead of alone on a
     * transparent canvas — the same all-roots view /snapshot captures.
     * (Window dim is a system layer, not a view, so it won't appear.)
     */
    private fun renderWindows(): Bitmap? {
        val roots = ReticleWindows.rootViews().filter { it.width > 0 && it.height > 0 }
        if (roots.isEmpty()) return null
        val loc = IntArray(2)
        var minX = Int.MAX_VALUE
        var minY = Int.MAX_VALUE
        var maxX = Int.MIN_VALUE
        var maxY = Int.MIN_VALUE
        val offsets = roots.map { root ->
            root.getLocationOnScreen(loc)
            minX = minOf(minX, loc[0])
            minY = minOf(minY, loc[1])
            maxX = maxOf(maxX, loc[0] + root.width)
            maxY = maxOf(maxY, loc[1] + root.height)
            loc[0] to loc[1]
        }
        if (maxX <= minX || maxY <= minY) return null
        val bitmap = Bitmap.createBitmap(maxX - minX, maxY - minY, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        roots.forEachIndexed { i, root ->
            val checkpoint = canvas.save()
            canvas.translate((offsets[i].first - minX).toFloat(), (offsets[i].second - minY).toFloat())
            root.draw(canvas)
            canvas.restoreToCount(checkpoint)
        }
        return bitmap
    }
}
