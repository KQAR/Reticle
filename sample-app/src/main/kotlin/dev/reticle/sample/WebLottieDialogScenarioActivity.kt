package dev.reticle.sample

import android.os.Bundle
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/**
 * A modal dialog rendered *inside* a WebView by `lottie-web` (a real Lottie
 * animation) plus DOM title / message / button. Probes whether Reticle's DOM
 * bridge folds in a web modal's recognizable elements while an animated `<svg>`
 * (the Lottie surface) sits in the same overlay.
 */
class WebLottieDialogScenarioActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val webView = SampleWebFixtures.createWebView(this, SampleWebFixtures.lottieDialogFixture(this)).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }
        setContentView(FrameLayout(this).apply { addView(webView) })
        Reticle.log("web_lottie_visible", mapOf("fixture" to "webLottie"))
    }
}
