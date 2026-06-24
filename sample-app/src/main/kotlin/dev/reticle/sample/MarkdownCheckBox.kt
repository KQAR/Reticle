package dev.reticle.sample

import android.content.Context
import android.view.MotionEvent
import androidx.appcompat.widget.AppCompatTextView

/**
 * A self-drawn checkbox+agreement control modeled on the real
 * com.lingyue ...MarkdownCheckBox found on a live login screen — including its
 * MULTIPLE 《…》 links on one row, the case that exposed the
 * collapse-into-one-block bug in the region probe.
 *
 * It IS a TextView subclass whose text is a plain String (getText() returns a
 * String, NOT a Spanned — no ClickableSpan). It splits N+1 regions — toggle +
 * one per 《…》 link — entirely inside its own onTouchEvent, by x/y coordinate
 * resolved through the View's Layout. No ClickableSpan, no child View, no
 * virtual a11y node.
 *
 * Reticle must flag it `suspectedMultiRegion` AND emit one textMarker region
 * per 《…》 link (each with its own rect) so an agent can target a specific
 * agreement rather than the whole link run.
 */
class MarkdownCheckBox(context: Context) : AppCompatTextView(context) {

    var onToggle: ((Boolean) -> Unit)? = null
    /** Invoked with the tapped link's text, e.g. "《隐私政策》". */
    var onLink: ((String) -> Unit)? = null

    private var checked = false
    private val body = "我已阅读并同意《用户协议》《隐私政策》《数字证书协议》"

    init {
        textSize = 16f
        text = render()
        isClickable = true
    }

    private fun render(): String = (if (checked) "☑ " else "☐ ") + body

    /** Character ranges of each 《…》 link in the current text. */
    private fun linkRanges(): List<IntRange> {
        val full = text.toString()
        val ranges = ArrayList<IntRange>()
        var i = 0
        while (true) {
            val open = full.indexOf('《', i)
            if (open < 0) break
            val close = full.indexOf('》', open + 1)
            if (close < 0) break
            ranges.add(open..close)
            i = close + 1
        }
        return ranges
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.action != MotionEvent.ACTION_UP) return true
        val layout = layout ?: return true
        val full = text.toString()
        val offset = layout.getOffsetForHorizontal(
            layout.getLineForVertical((event.y - totalPaddingTop + scrollY).toInt()),
            event.x - totalPaddingLeft + scrollX,
        )
        val hit = linkRanges().firstOrNull { offset in it.first..it.last }
        if (hit != null) {
            onLink?.invoke(full.substring(hit.first, hit.last + 1))
        } else {
            checked = !checked
            text = render()
            onToggle?.invoke(checked)
        }
        return true
    }
}
