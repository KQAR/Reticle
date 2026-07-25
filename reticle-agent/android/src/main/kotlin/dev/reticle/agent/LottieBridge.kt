package dev.reticle.agent

import android.graphics.Paint
import android.view.View
import android.widget.ImageView
import dev.reticle.core.InteractionRegion
import dev.reticle.core.Rect
import dev.reticle.core.RegionSource

/**
 * Looks inside a Lottie animation.
 *
 * A Lottie renders its whole UI — text and shapes — into one opaque canvas, so
 * the view tree sees a single `LottieAnimationView` node. When an app bakes a
 * dialog's title / message / buttons into the animation, none of that is a real
 * view, an accessibility node, or a DOM element, so nothing downstream can act
 * on it. This bridge recovers those elements from the *parsed composition* Lottie
 * already holds in memory: it enumerates the named layers, reads text layers'
 * strings, and maps each layer's transform through the composition→view scale to
 * a screen rect — surfaced as [RegionSource.lottie] sub-regions so the existing
 * region pipeline (`ui regions`, `act tap --region`) can target them.
 *
 * Pure reflection: the agent must not link Lottie (a target app may not use it).
 * Every step is guarded — an absent class, a renamed field, or an unexpected
 * shape yields no regions rather than a crash. Geometry comes from the same model
 * Lottie draws from; the "this layer is a button" inference is a hint (the label
 * is the layer's own text, or its author-given name).
 */
object LottieBridge {

    private const val VIEW_CLASS = "com.airbnb.lottie.LottieAnimationView"

    fun regionsFor(view: View, screenFrame: Rect?): List<InteractionRegion> {
        if (screenFrame == null) return emptyList()
        if (!isLottieView(view)) return emptyList()
        return try {
            val composition = invoke(view, "getComposition") ?: return emptyList()
            val bounds = invoke(composition, "getBounds") ?: return emptyList()
            val compW = (invoke(bounds, "width") as? Int)?.toDouble() ?: return emptyList()
            val compH = (invoke(bounds, "height") as? Int)?.toDouble() ?: return emptyList()
            if (compW <= 0 || compH <= 0) return emptyList()

            @Suppress("UNCHECKED_CAST")
            val layers = invoke(composition, "getLayers") as? List<Any?> ?: return emptyList()
            val map = ViewMap.of(view, screenFrame, compW, compH)

            layers.mapNotNull { layer -> layer?.let { regionForLayer(it, map) } }
        } catch (_: Throwable) {
            emptyList()
        }
    }

    private fun isLottieView(view: View): Boolean {
        var c: Class<*>? = view.javaClass
        while (c != null) {
            if (c.name == VIEW_CLASS) return true
            c = c.superclass
        }
        return false
    }

    /** One text layer -> one region. Non-text layers are skipped (no label). */
    private fun regionForLayer(layer: Any, map: ViewMap): InteractionRegion? {
        val type = invoke(layer, "getLayerType")?.let { (it as? Enum<*>)?.name }
        if (type != "TEXT") return null

        val textFrame = accessibleInvoke(layer, "getText") ?: return null
        @Suppress("UNCHECKED_CAST")
        val keyframes = invoke(textFrame, "getKeyframes") as? List<Any?> ?: return null
        val doc = keyframes.firstNotNullOfOrNull { it?.let { kf -> field(kf, "startValue") } } ?: return null
        val text = (field(doc, "text") as? String)?.takeIf { it.isNotBlank() } ?: return null
        val size = (field(doc, "size") as? Float)?.toDouble() ?: 12.0
        val justify = (field(doc, "justification") as? Enum<*>)?.name ?: "LEFT_JUSTIFY"

        val transform = accessibleInvoke(layer, "getTransform") ?: return null
        val pos = firstPoint(invoke(transform, "getPosition")) ?: return null
        val anchor = firstPoint(invoke(transform, "getAnchorPoint")) ?: (0.0 to 0.0)
        val cx = pos.first - anchor.first
        val cy = pos.second - anchor.second

        // Measure the real glyph extent instead of estimating from char count —
        // accurate for proportional fonts and CJK/Latin/emoji runs.
        val paint = Paint().apply { textSize = size.toFloat() }
        val glyphW = paint.measureText(text).toDouble()
        val fm = paint.fontMetrics
        val glyphH = (fm.descent - fm.ascent).toDouble()

        // The authored text box (`sz`/`ps` in the Lottie), when present, gives the
        // exact anchor + layout region the glyphs are placed within; fall back to
        // the layer origin otherwise.
        val boxLeft = cx + (pointField(field(doc, "boxPosition"), "x") ?: 0.0)
        val boxTop = cy + (pointField(field(doc, "boxPosition"), "y") ?: 0.0)
        val boxW = pointField(field(doc, "boxSize"), "x")?.takeIf { it > 0 }
        val boxH = pointField(field(doc, "boxSize"), "y")?.takeIf { it > 0 }

        // Place the measured glyph rect by justification within the box (or at the
        // origin when unboxed), so the rect hugs the text and its center is a
        // reliable tap point.
        val anchorX = when (justify) {
            "CENTER" -> boxW?.let { boxLeft + it / 2 } ?: cx
            "RIGHT_JUSTIFY" -> boxW?.let { boxLeft + it } ?: cx
            else -> if (boxW != null) boxLeft else cx
        }
        val left = when (justify) {
            "CENTER" -> anchorX - glyphW / 2
            "RIGHT_JUSTIFY" -> anchorX - glyphW
            else -> anchorX
        }
        val centerY = boxH?.let { boxTop + it / 2 } ?: cy
        val top = centerY - glyphH / 2

        return InteractionRegion(
            source = RegionSource.lottie,
            label = text,
            rects = listOf(map.rect(left, top, glyphW, glyphH)),
        )
    }

    /** A public `PointF` field's component as a Double, or null. */
    private fun pointField(point: Any?, axis: String): Double? =
        point?.let { (field(it, axis) as? Float)?.toDouble() }

    /** Composition-space -> screen-space mapping for the view's scaleType. */
    private class ViewMap(
        val originX: Double, val originY: Double,
        val offX: Double, val offY: Double,
        val sx: Double, val sy: Double,
    ) {
        fun rect(cxLeft: Double, cyTop: Double, w: Double, h: Double): Rect = Rect(
            x = originX + offX + cxLeft * sx,
            y = originY + offY + cyTop * sy,
            width = w * sx,
            height = h * sy,
        )

        companion object {
            fun of(view: View, frame: Rect, compW: Double, compH: Double): ViewMap {
                val fitXy = (view as? ImageView)?.scaleType == ImageView.ScaleType.FIT_XY
                return if (fitXy) {
                    ViewMap(frame.x, frame.y, 0.0, 0.0, frame.width / compW, frame.height / compH)
                } else {
                    // FIT_CENTER / CENTER_INSIDE — the LottieAnimationView default:
                    // uniform min-scale, centered.
                    val s = minOf(frame.width / compW, frame.height / compH)
                    ViewMap(
                        frame.x, frame.y,
                        (frame.width - compW * s) / 2, (frame.height - compH * s) / 2,
                        s, s,
                    )
                }
            }
        }
    }

    /** First keyframe's start value of an AnimatablePathValue, as (x, y). */
    private fun firstPoint(pathValue: Any?): Pair<Double, Double>? {
        pathValue ?: return null
        @Suppress("UNCHECKED_CAST")
        val keyframes = (invoke(pathValue, "getKeyframes") as? List<Any?>) ?: return null
        val point = keyframes.firstNotNullOfOrNull { it?.let { kf -> field(kf, "startValue") } } ?: return null
        val x = (field(point, "x") as? Float)?.toDouble() ?: return null
        val y = (field(point, "y") as? Float)?.toDouble() ?: return null
        return x to y
    }

    // --- reflection helpers (all null-safe) ---

    private fun invoke(target: Any, method: String): Any? = try {
        target.javaClass.getMethod(method).invoke(target)
    } catch (_: Throwable) {
        null
    }

    /** Invoke a (possibly package-private) no-arg method, walking up the class. */
    private fun accessibleInvoke(target: Any, method: String): Any? {
        var c: Class<*>? = target.javaClass
        while (c != null) {
            try {
                val m = c.getDeclaredMethod(method)
                m.isAccessible = true
                return m.invoke(target)
            } catch (_: NoSuchMethodException) {
                c = c.superclass
            } catch (_: Throwable) {
                return null
            }
        }
        return null
    }

    private fun field(target: Any, name: String): Any? {
        var c: Class<*>? = target.javaClass
        while (c != null) {
            try {
                val f = c.getDeclaredField(name)
                f.isAccessible = true
                return f.get(target)
            } catch (_: NoSuchFieldException) {
                c = c.superclass
            } catch (_: Throwable) {
                return null
            }
        }
        return null
    }
}
