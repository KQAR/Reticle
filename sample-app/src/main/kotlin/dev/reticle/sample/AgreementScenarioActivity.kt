package dev.reticle.sample

import android.os.Bundle
import android.text.SpannableString
import android.text.Spanned
import android.text.method.LinkMovementMethod
import android.text.style.ClickableSpan
import android.text.style.ForegroundColorSpan
import android.view.Gravity
import android.view.View
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/**
 * Multi-region text cases that collapse into one View but still need precise
 * phrase-level targeting.
 */
class AgreementScenarioActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 48)
        }

        val status = TextView(this).apply {
            text = "Agreement scenarios"
            textSize = 20f
            tag = "agreement.status"
        }

        root.addView(status)
        root.addView(clickableSpanRow(status))
        root.addView(markdownRow(status))
        root.addView(plainPhraseRow(status))
        root.addView(colorSpanRow(status))
        setContentView(root)

        Reticle.log("agreements_visible", mapOf("cases" to 4))
    }

    private fun clickableSpanRow(status: TextView): TextView {
        val agreementText = "I have read and agree to the Terms"
        val linkStart = agreementText.indexOf("Terms")
        val linkEnd = agreementText.length
        return TextView(this).apply {
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
    }

    private fun markdownRow(status: TextView): MarkdownCheckBox =
        MarkdownCheckBox(this).apply {
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

    private fun plainPhraseRow(status: TextView): PlainPhraseAgreement =
        PlainPhraseAgreement(this).apply {
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

    private fun colorSpanRow(status: TextView): TextView {
        val colorBlue = 0xFF1A73E8.toInt()
        val colorText = "Continue means you accept the Terms of Service"
        val colorPhrase = "Terms of Service"
        val cStart = colorText.indexOf(colorPhrase)
        return TextView(this).apply {
            tag = "agreement.color"
            textSize = 16f
            val sp = SpannableString(colorText)
            sp.setSpan(ForegroundColorSpan(colorBlue), cStart, cStart + colorPhrase.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            text = sp
            isClickable = true
            setOnClickListener {
                status.text = "tapped color row (manual hit-test)"
                Reticle.log("color_row_clicked", mapOf("highlight" to colorPhrase))
            }
        }
    }
}
