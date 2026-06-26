package dev.reticle.sample

import android.content.Context
import android.view.MotionEvent
import androidx.appcompat.widget.AppCompatTextView

/**
 * A self-drawn checkbox+agreement control modeled on a real login-screen pattern
 * — a single row carrying MULTIPLE bracketed links, the case that exposed the
 * collapse-into-one-block bug in the region probe.
 *
 * It IS a TextView subclass whose text is a plain String (getText() returns a
 * String, NOT a Spanned — no ClickableSpan). It splits N+1 regions — toggle +
 * one per bracketed link — entirely inside its own onTouchEvent, by x/y
 * coordinate resolved through the View's Layout. No ClickableSpan, no child
 * View, no virtual a11y node.
 *
 * Reticle must flag it `suspectedMultiRegion` AND emit one textMarker region per
 * bracketed link (each with its own rect) so an agent can target a specific
 * agreement rather than the whole link run. The links here deliberately mix
 * bracket scripts — European «…» and CJK 《…》 on one row — to exercise the
 * script-agnostic marker detection (RegionProbe.BRACKET_PAIRS).
 */
class MarkdownCheckBox(context: Context) : AppCompatTextView(context) {

    var onToggle: ((Boolean) -> Unit)? = null
    /** Invoked with the tapped link's text, e.g. "«Terms»". */
    var onLink: ((String) -> Unit)? = null

    private var checked = false
    private val body = "I have read and agree to «Terms» «Privacy» 《Data》"

    /** Open/close bracket pairs whose runs are tappable links, any script. */
    private val brackets = listOf('«' to '»', '《' to '》')

    init {
        textSize = 16f
        text = render()
        isClickable = true
    }

    private fun render(): String = (if (checked) "☑ " else "☐ ") + body

    /** Character ranges of each bracketed link in the current text. */
    private fun linkRanges(): List<IntRange> {
        val full = text.toString()
        val ranges = ArrayList<IntRange>()
        for ((open, close) in brackets) {
            var i = 0
            while (true) {
                val o = full.indexOf(open, i)
                if (o < 0) break
                val c = full.indexOf(close, o + 1)
                if (c < 0) break
                ranges.add(o..c)
                i = c + 1
            }
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
