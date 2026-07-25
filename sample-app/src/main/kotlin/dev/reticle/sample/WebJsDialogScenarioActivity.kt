package dev.reticle.sample

import android.os.Bundle
import android.view.ViewGroup
import android.webkit.JsResult
import android.webkit.WebChromeClient
import android.webkit.WebView
import android.widget.FrameLayout
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/**
 * A web page that raises a NATIVE modal from JavaScript.
 *
 * This is not "one more dialog": `alert()` blocks the page's JS thread until the
 * app dismisses it, so while the modal is up the DOM bridge's
 * `evaluateJavascript` can never call back. The bridge must therefore degrade to
 * its honest L0 — the WebView stays an opaque view node — instead of hanging the
 * capture, and the native modal itself must still be recognized. Android shows a
 * JS alert only if the app implements `onJsAlert`, which is exactly what real
 * apps do, so the app-owned `AlertDialog` here is the realistic shape.
 */
class WebJsDialogScenarioActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val webView = SampleWebFixtures.createWebView(this, SampleWebFixtures.webJsDialogFixture()).apply {
            webChromeClient = object : WebChromeClient() {
                override fun onJsAlert(
                    view: WebView?,
                    url: String?,
                    message: String?,
                    result: JsResult?,
                ): Boolean {
                    Reticle.log("web_js_alert_shown", mapOf("message" to (message ?: "")))
                    AlertDialog.Builder(this@WebJsDialogScenarioActivity)
                        .setTitle("Message from the page")
                        .setMessage(message)
                        .setPositiveButton("OK") { _, _ ->
                            // Confirming releases the blocked JS thread, which is
                            // what makes the DOM bridge usable again.
                            result?.confirm()
                            Reticle.log("web_js_alert_dismissed", emptyMap())
                        }
                        .setCancelable(false)
                        .show()
                    return true
                }
            }
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }
        setContentView(FrameLayout(this).apply { addView(webView) })
        Reticle.log("web_js_dialog_visible", mapOf("fixture" to "jsDialog"))
    }
}
