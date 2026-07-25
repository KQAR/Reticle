package dev.reticle.sample

import android.graphics.Rect
import android.os.Bundle
import android.view.Gravity
import android.view.TouchDelegate
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/**
 * The two region channels that a self-drawn control exposes through documented
 * runtime mechanisms, and that no other scenario covers:
 *
 *  - **virtual accessibility nodes** (`getAccessibilityNodeProvider()` /
 *    `ExploreByTouchHelper`): two canvas controls, one with dense 0-based
 *    virtual ids and one with stable offset ids — both legal, both common.
 *  - **touch delegate** (`getTouchDelegate()`): a 20px icon whose real hit area
 *    is expanded by its parent, so the tappable rect is nowhere near the view
 *    frame the tree reports.
 *
 * Every region carries an observable side effect, so a tap driven from a
 * recovered rect can be told apart from a tap that merely didn't error.
 */
class CanvasControlScenarioActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 48)
        }

        val status = TextView(this).apply {
            text = "Idle"
            textSize = 20f
            tag = "canvas.status"
        }
        root.addView(status)

        // Channel 2a: virtual a11y nodes with dense 0-based ids.
        root.addView(
            VirtualNodeCanvasControl(this, DENSE_LABELS, idBase = 0).apply {
                tag = "canvas.segments"
                onSegment = { label ->
                    status.text = "Segment: $label"
                    Reticle.log("canvas_segment_picked", mapOf("label" to label, "ids" to "dense"))
                }
            },
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 160),
        )

        // Channel 2b: the same control with stable, non-zero-based ids (a seat
        // number / row id, as real apps assign).
        root.addView(
            VirtualNodeCanvasControl(this, STABLE_LABELS, idBase = STABLE_ID_BASE).apply {
                tag = "canvas.seats"
                onSegment = { label ->
                    status.text = "Seat: $label"
                    Reticle.log("canvas_seat_picked", mapOf("label" to label, "ids" to "stable"))
                }
            },
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 160),
        )

        root.addView(touchDelegateRow(status))
        setContentView(root)

        Reticle.log("canvas_control_visible", mapOf("channels" to "a11yVirtual+touchDelegate"))
    }

    /**
     * A tiny icon pinned to the LEFT of a full-width row, with the row installing
     * a [TouchDelegate] over its whole area — the everyday "expand the checkbox's
     * hit area to the row" pattern.
     *
     * The asymmetry is deliberate: the delegate rect's center is nowhere near the
     * icon's own 20x20 frame, so a tap driven from the recovered rect can only
     * reach the icon through the delegate. Tapping the view frame instead would
     * prove nothing.
     */
    private fun touchDelegateRow(status: TextView): View {
        val icon = TextView(this).apply {
            tag = "canvas.icon"
            text = "x"
            textSize = 10f
            // A real icon button carries one; it is also the only identity a
            // TouchDelegateInfo target exposes, so it labels the forwarded rect.
            contentDescription = "Close"
            setOnClickListener {
                status.text = "Icon tapped"
                Reticle.log("canvas_icon_tapped", mapOf("via" to "touchDelegate"))
            }
        }
        val container = FrameLayout(this).apply {
            tag = "canvas.iconHost"
            addView(icon, FrameLayout.LayoutParams(ICON_SIZE, ICON_SIZE).apply {
                gravity = Gravity.START or Gravity.CENTER_VERTICAL
            })
        }
        container.post {
            // The forwarded rect is the WHOLE row, so its center is far from the
            // icon — the delegate is the only way a center tap reaches it.
            container.touchDelegate = TouchDelegate(
                Rect(0, 0, container.width, container.height),
                icon,
            )
        }
        return container.also {
            it.layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                ROW_HEIGHT,
            )
        }
    }

    private companion object {
        val DENSE_LABELS = listOf("Daily", "Weekly", "Monthly")
        val STABLE_LABELS = listOf("A1", "A2", "A3")

        /** Stable ids far from 0 — the case a 0-based probe misses. */
        const val STABLE_ID_BASE = 4101

        const val ICON_SIZE = 20
        const val ROW_HEIGHT = 140
    }
}
