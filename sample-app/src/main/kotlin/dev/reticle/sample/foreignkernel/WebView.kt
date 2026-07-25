package dev.reticle.sample.foreignkernel

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.view.View

/**
 * A stand-in for a third-party WebView kernel (X5/TBS, UC): a class that calls
 * itself `WebView` but is NOT an `android.webkit.WebView`, drawing its "page"
 * itself.
 *
 * That is the whole shape Reticle keys on, and the reason a real kernel loses the
 * DOM capability outright: `WebViewBridge` is typed on the platform class, so it
 * cannot attach to `com.tencent.smtt.sdk.WebView` any more than it can to this.
 * Using our own package rather than squatting a vendor's keeps the fixture honest —
 * the shipped rule is the shape test, not a vendor list, so this exercises exactly
 * what ships. What it cannot prove (and nothing here claims) is that a real X5 page
 * would otherwise have been readable.
 */
class WebView(context: Context) : View(context) {

    private val background = Paint().apply { color = Color.parseColor("#101828") }
    private val text = Paint().apply {
        color = Color.WHITE
        textSize = 44f
        isAntiAlias = true
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), background)
        canvas.drawText("Third-party kernel page", 32f, 90f, text)
        canvas.drawText("(self-drawn: no DOM to read)", 32f, 160f, text)
    }
}
