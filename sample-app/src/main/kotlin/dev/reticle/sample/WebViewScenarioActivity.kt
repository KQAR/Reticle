package dev.reticle.sample

import android.os.Bundle
import android.util.TypedValue
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/** Full-screen embedded WebView below the platform-provided app navigation bar. */
class WebViewScenarioActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "WebView DOM"
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        val webView = SampleWebFixtures.createWebView(this, SampleWebFixtures.resolve(intent)).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ).apply {
                topMargin = statusBarHeightPx() + actionBarHeightPx()
            }
        }
        setContentView(FrameLayout(this).apply { addView(webView) })
        Reticle.log("webview_visible", mapOf("fixture" to "checkout"))
    }

    override fun onSupportNavigateUp(): Boolean {
        finish()
        return true
    }

    private fun actionBarHeightPx(): Int {
        val typedValue = TypedValue()
        return if (theme.resolveAttribute(android.R.attr.actionBarSize, typedValue, true)) {
            TypedValue.complexToDimensionPixelSize(typedValue.data, resources.displayMetrics)
        } else {
            0
        }
    }

    private fun statusBarHeightPx(): Int {
        val id = resources.getIdentifier("status_bar_height", "dimen", "android")
        return if (id > 0) resources.getDimensionPixelSize(id) else 0
    }
}
