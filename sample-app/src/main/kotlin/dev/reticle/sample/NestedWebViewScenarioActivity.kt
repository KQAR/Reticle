package dev.reticle.sample

import android.os.Bundle
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/**
 * Two live WebViews in one window, the second stacked over the first at an offset.
 *
 * Every other web fixture has exactly one WebView filling its parent, where a
 * dropped or mis-attributed container offset is invisible: the frame origin is the
 * screen origin, so wrong arithmetic and right arithmetic agree. This is the shape
 * a hybrid app actually has — a host page that pushes a second web container over
 * itself for a third-party step — and it is where a coordinate error would show up.
 *
 * The second WebView is deliberately NOT full-bleed: it sits inset from the left
 * and well down the screen, so its DOM rects only land on the real pixels if the
 * fold adds that container's own offset rather than the first WebView's.
 *
 * Both pages carry an `onclick`, which is the whole point — a COORDINATE tap is
 * the only thing that can tell a correct rect from a plausible one. DOM activation
 * would fire the handler even if the reported geometry were nonsense.
 */
class NestedWebViewScenarioActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "Nested WebViews"
        supportActionBar?.setDisplayHomeAsUpEnabled(true)

        val root = FrameLayout(this)

        val backdrop = SampleWebFixtures.createWebView(
            this,
            SampleWebFixtures.nestedBackdropFixture(),
        ).apply {
            tag = "nested.backdropWebView"
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }

        val overlay = SampleWebFixtures.createWebView(
            this,
            SampleWebFixtures.nestedOverlayFixture(),
        ).apply {
            tag = "nested.overlayWebView"
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            ).apply {
                // Inset on both axes: an offset dropped from either one puts the
                // reported rect on the backdrop's coordinates instead of this
                // view's, which is exactly the failure being pinned.
                leftMargin = dp(24)
                topMargin = dp(220)
            }
        }

        root.addView(backdrop)
        root.addView(overlay)
        setContentView(root)
        Reticle.log("nested_webviews_visible", mapOf("count" to "2"))
    }

    override fun onSupportNavigateUp(): Boolean {
        finish()
        return true
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}
