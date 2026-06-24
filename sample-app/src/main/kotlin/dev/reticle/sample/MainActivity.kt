package dev.reticle.sample

import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.method.LinkMovementMethod
import android.text.style.ClickableSpan
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/**
 * Demo screen proving the Reticle round trip AND the two multi-region cases the
 * span/region probe targets:
 *
 *   A) agreementSpan — a TextView with a ClickableSpan: one View, two regions
 *      (toggle text + 《Agreement》 link). RECOVERABLE via the span channel.
 *   B) MarkdownCheckBox — a self-drawn control that splits toggle vs. link in
 *      its own onTouchEvent, with plain-String text and no spans. NOT
 *      recoverable via any standard channel — must be flagged
 *      suspectedMultiRegion and targeted via the char grid.
 *
 * This mirrors the real-app finding (com.lingyue ...MarkdownCheckBox).
 */
class MainActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 48)
        }

        val status = TextView(this).apply {
            text = "Cart: 3 items"
            textSize = 20f
            tag = "checkout.status"
        }

        val payButton = Button(this).apply {
            text = "Pay now"
            tag = "checkout.payButton"
            setOnClickListener {
                status.text = "Paid!"
                Reticle.log("checkout_paid", mapOf("itemCount" to 3, "method" to "card"))
            }
        }

        // Case A: standard ClickableSpan agreement row.
        val agreementText = "我已阅读并同意《用户协议》"
        val linkStart = agreementText.indexOf('《')
        val linkEnd = agreementText.length
        val agreementSpan = TextView(this).apply {
            tag = "agreement.span"
            textSize = 16f
            val spannable = SpannableString(agreementText)
            spannable.setSpan(object : ClickableSpan() {
                override fun onClick(widget: View) {
                    status.text = "opened agreement (span link)"
                    Reticle.log("agreement_link_clicked", mapOf("via" to "ClickableSpan"))
                }
            }, linkStart, linkEnd, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            text = spannable
            movementMethod = LinkMovementMethod.getInstance()
        }

        // Case B: self-drawn control, two regions in its own onTouchEvent.
        val markdownCheck = MarkdownCheckBox(this).apply {
            tag = "agreement.markdown"
            onToggle = { checked ->
                status.text = if (checked) "agreed (markdown toggle)" else "unchecked"
                Reticle.log("markdown_toggled", mapOf("checked" to checked))
            }
            onLink = { linkText ->
                status.text = "opened $linkText (markdown link)"
                Reticle.log("markdown_link_clicked", mapOf("via" to "onTouchEvent", "link" to linkText))
            }
        }

        // Case C: self-drawn, multiple tappable phrases with NO markers at all.
        val plainPhrase = PlainPhraseAgreement(this).apply {
            tag = "agreement.plain"
            onPhrase = { phrase ->
                status.text = "opened $phrase (plain phrase)"
                Reticle.log("plain_phrase_clicked", mapOf("phrase" to phrase))
            }
            onPlain = {
                status.text = "tapped agreement text (no phrase)"
                Reticle.log("plain_text_clicked", emptyMap())
            }
        }

        // Case D: a colored phrase that is NOT a ClickableSpan — the
        // "highlight = link" pattern. "服务条款" is tinted blue via a
        // ForegroundColorSpan; the whole row has one OnClickListener that
        // hit-tests the colored run. Reticle should surface a colorSpan region
        // with the actual color, even though there is no ClickableSpan.
        val colorBlue = 0xFF1A73E8.toInt()
        val colorText = "继续即表示接受服务条款"
        val cStart = colorText.indexOf("服务条款")
        val colorPhrase = TextView(this).apply {
            tag = "agreement.color"
            textSize = 16f
            val sp = SpannableString(colorText)
            sp.setSpan(android.text.style.ForegroundColorSpan(colorBlue), cStart, cStart + 4, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            text = sp
            isClickable = true
            setOnClickListener {
                status.text = "tapped color row (manual hit-test)"
                Reticle.log("color_row_clicked", mapOf("highlight" to "服务条款"))
            }
        }

        root.addView(status)
        root.addView(payButton)
        root.addView(agreementSpan)
        root.addView(markdownCheck)
        root.addView(plainPhrase)
        root.addView(colorPhrase)
        setContentView(root)

        // App-authored evidence via the log / view-metadata bridge.
        Reticle.attachMetadata("checkout.payButton", mapOf("screen" to "checkout", "variant" to "primary"))
        Reticle.log("checkout_visible", mapOf("cartId" to "cart-123", "itemCount" to 3))
    }
}
