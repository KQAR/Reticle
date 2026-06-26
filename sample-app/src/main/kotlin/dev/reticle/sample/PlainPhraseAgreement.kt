package dev.reticle.sample

import android.content.Context
import android.view.MotionEvent
import androidx.appcompat.widget.AppCompatTextView

/**
 * The hardest real case: a self-drawn clickable text with MULTIPLE tappable
 * phrases that carry NO bracket / markdown / span markers at all —
 * "By signing in you accept the User Agreement and Privacy Policy", where only
 * "User Agreement" and "Privacy Policy" are meant to be tappable. The phrase
 * boundaries live purely in the app's private onTouchEvent character-range check.
 *
 * Nothing structural marks the phrases, so Reticle cannot DISCOVER them as
 * regions and — by design — does NOT flag `suspectedMultiRegion` either (it
 * never guesses link-ness from wording, which would tie the probe to one
 * language). But because the rendered text is visible and the char grid gives
 * exact per-character X, an agent can still target a phrase precisely with
 * `act tap --region "User Agreement"` / `--region "Privacy Policy"`.
 */
class PlainPhraseAgreement(context: Context) : AppCompatTextView(context) {

    var onPhrase: ((String) -> Unit)? = null
    var onPlain: (() -> Unit)? = null

    private val body = "By signing in you accept the User Agreement and Privacy Policy"
    private val phrases = listOf("User Agreement", "Privacy Policy")

    init {
        // Non-default metrics on purpose: the char grid is sourced from Layout,
        // so larger text + letter-spacing + line-spacing must still resolve a
        // phrase precisely (verified on-device). Keeping them here doubles as a
        // standing regression for font/size/spacing robustness.
        textSize = 18f
        letterSpacing = 0.1f
        setLineSpacing(16f, 1.3f)
        text = body
        isClickable = true
    }

    private fun ranges(): List<Pair<String, IntRange>> = phrases.mapNotNull { p ->
        val i = body.indexOf(p)
        if (i < 0) null else p to (i..(i + p.length - 1))
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.action != MotionEvent.ACTION_UP) return true
        val layout = layout ?: return true
        val line = layout.getLineForVertical((event.y - totalPaddingTop + scrollY).toInt())
        val offset = layout.getOffsetForHorizontal(line, event.x - totalPaddingLeft + scrollX)
        val hit = ranges().firstOrNull { offset in it.second }
        if (hit != null) onPhrase?.invoke(hit.first) else onPlain?.invoke()
        return true
    }
}
