package dev.reticle.sample

import android.os.Bundle
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/**
 * A screen whose "web view" is a third-party kernel — the capability Reticle
 * structurally does not have, made visible.
 *
 * `WebViewBridge` is typed on `android.webkit.WebView`, so an X5/TBS or UC kernel
 * gets no DOM at any level: no `--css` selector, no styles, no piercing. Before,
 * that looked exactly like a page that happened to be empty. The point of this
 * scenario is that the capture now says which it is (`dom:unsupported-kernel`, with
 * the class name as evidence), while a REAL `android.webkit.WebView` next to it
 * keeps its DOM — the contrast is what makes the marker meaningful.
 */
class ForeignKernelScenarioActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val status = TextView(this).apply {
            text = "Two web views: one kernel Reticle cannot read, one it can"
            tag = "kernel.status"
        }

        val foreign = dev.reticle.sample.foreignkernel.WebView(this).apply {
            tag = "kernel.foreign"
            contentDescription = "Third-party kernel view"
        }

        val real = android.webkit.WebView(this).apply {
            tag = "kernel.real"
            settings.javaScriptEnabled = true
            loadDataWithBaseURL(
                null,
                "<html><body style='font:16px sans-serif'>" +
                    "<p id='kernel-real'>Real WebView DOM</p></body></html>",
                "text/html",
                "utf-8",
                null,
            )
        }

        setContentView(
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                setPadding(48, 48, 48, 48)
                addView(status)
                addView(foreign, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 400))
                addView(real, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 400))
            }
        )
        Reticle.log("foreign_kernel_visible", mapOf("screen" to "foreignKernel"))
    }
}
