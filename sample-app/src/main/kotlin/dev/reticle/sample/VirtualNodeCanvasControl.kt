package dev.reticle.sample

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.view.MotionEvent
import android.view.View
import androidx.core.view.ViewCompat
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import androidx.customview.widget.ExploreByTouchHelper

/**
 * A self-drawn control: N segments painted straight onto the canvas, with no
 * child views. The plain view tree sees ONE node, so the segment labels and
 * their rects are only recoverable through the officially sanctioned channel —
 * virtual accessibility nodes via `getAccessibilityNodeProvider()`
 * (`ExploreByTouchHelper`). This is the same shape as a real chart, calendar,
 * seat map, or self-drawn keypad.
 *
 * [idBase] is the deliberate variable. `ExploreByTouchHelper` lets the app choose
 * its virtual view ids, and real apps pick either dense 0-based indexes or stable
 * domain ids (a seat number, a row id). Both are legal; a harness that only
 * recovers one of them silently loses half the real-world cases, so the sample
 * ships one control of each.
 */
class VirtualNodeCanvasControl(
    context: Context,
    private val labels: List<String>,
    private val idBase: Int,
) : View(context) {

    /** Fired when a segment is picked, by touch or by an a11y click action. */
    var onSegment: ((String) -> Unit)? = null

    private var selected = 0

    private val boxPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.WHITE
        textSize = 40f
        textAlign = Paint.Align.CENTER
    }

    private val helper = object : ExploreByTouchHelper(this) {
        override fun getVirtualViewAt(x: Float, y: Float): Int {
            val index = indexAt(x)
            return if (index < 0) HOST_ID else idBase + index
        }

        override fun getVisibleVirtualViews(virtualViewIds: MutableList<Int>) {
            labels.indices.forEach { virtualViewIds.add(idBase + it) }
        }

        override fun onPopulateNodeForVirtualView(
            virtualViewId: Int,
            node: AccessibilityNodeInfoCompat,
        ) {
            val index = virtualViewId - idBase
            if (index !in labels.indices) {
                // ExploreByTouchHelper requires non-empty parent bounds even for
                // an id it will discard.
                @Suppress("DEPRECATION")
                node.setBoundsInParent(Rect(0, 0, 1, 1))
                return
            }
            node.contentDescription = labels[index]
            node.className = "android.widget.Button"
            node.isSelected = index == selected
            node.addAction(AccessibilityNodeInfoCompat.ACTION_CLICK)
            @Suppress("DEPRECATION")
            node.setBoundsInParent(boundsOf(index))
        }

        override fun onPerformActionForVirtualView(
            virtualViewId: Int,
            action: Int,
            arguments: android.os.Bundle?,
        ): Boolean {
            if (action != AccessibilityNodeInfoCompat.ACTION_CLICK) return false
            val index = virtualViewId - idBase
            if (index !in labels.indices) return false
            select(index)
            return true
        }
    }

    init {
        ViewCompat.setAccessibilityDelegate(this, helper)
    }

    override fun dispatchHoverEvent(event: MotionEvent): Boolean =
        helper.dispatchHoverEvent(event) || super.dispatchHoverEvent(event)

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(
            resolveSize((labels.size * SEGMENT_W).toInt(), widthMeasureSpec),
            resolveSize(SEGMENT_H.toInt(), heightMeasureSpec),
        )
    }

    override fun onDraw(canvas: Canvas) {
        labels.forEachIndexed { index, label ->
            val bounds = boundsOf(index)
            boxPaint.color = if (index == selected) SELECTED_COLOR else IDLE_COLOR
            canvas.drawRect(bounds, boxPaint)
            canvas.drawText(
                label,
                bounds.exactCenterX(),
                bounds.exactCenterY() + textPaint.textSize / 3f,
                textPaint,
            )
        }
    }

    /**
     * The control hit-tests taps itself — exactly like the real controls this
     * models, where the tappable regions exist only inside `onTouchEvent`.
     */
    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (event.action != MotionEvent.ACTION_UP) return true
        val index = indexAt(event.x)
        if (index >= 0) select(index)
        return true
    }

    private fun select(index: Int) {
        selected = index
        invalidate()
        onSegment?.invoke(labels[index])
    }

    private fun indexAt(x: Float): Int {
        val index = (x / segmentWidth()).toInt()
        return if (index in labels.indices) index else -1
    }

    private fun segmentWidth(): Float =
        if (width > 0) width.toFloat() / labels.size else SEGMENT_W

    private fun boundsOf(index: Int): Rect {
        val w = segmentWidth()
        val h = if (height > 0) height else SEGMENT_H.toInt()
        return Rect(
            (index * w).toInt() + GAP,
            GAP,
            ((index + 1) * w).toInt() - GAP,
            h - GAP,
        )
    }

    private companion object {
        const val SEGMENT_W = 260f
        const val SEGMENT_H = 160f
        const val GAP = 6
        const val IDLE_COLOR = 0xFF546E7A.toInt()
        const val SELECTED_COLOR = 0xFF1A73E8.toInt()
    }
}
