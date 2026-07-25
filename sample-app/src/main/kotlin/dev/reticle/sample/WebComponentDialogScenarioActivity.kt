package dev.reticle.sample

import android.os.Bundle
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/**
 * A modal dialog rendered inside a WebView as a Web Component — a custom
 * `<confirm-dialog>` element whose title / message / buttons live in an *open
 * shadow root*. Probes whether Reticle pierces the shadow boundary and folds the
 * modal's elements into the unified tree with correct content and frames.
 */
class WebComponentDialogScenarioActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val webView = SampleWebFixtures.createWebView(this, SampleWebFixtures.webComponentDialogFixture()).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }
        setContentView(FrameLayout(this).apply { addView(webView) })
        Reticle.log("web_component_visible", mapOf("fixture" to "webComponent"))
    }
}
