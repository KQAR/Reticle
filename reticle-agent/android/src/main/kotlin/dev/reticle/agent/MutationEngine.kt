package dev.reticle.agent

import android.content.Context
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.TextView
import dev.reticle.core.MetadataValue
import dev.reticle.core.MutationRequest
import dev.reticle.core.MutationResult
import dev.reticle.core.Selector

/**
 * Allowlisted runtime property mutation: only a bounded set of View properties
 * may be patched live so UI diagnosis and design iteration can happen from the
 * CLI without rebuilding the app.
 *
 * Compose nodes are intentionally NOT mutable here: immutable declarative trees
 * must be driven through app-owned state, not patched from the outside.
 */
class MutationEngine(private val context: Context) {

    private val handler = Handler(Looper.getMainLooper())

    private val allowedProperties =
        setOf("alpha", "visibility", "text", "backgroundColor", "textColor", "textSize", "enabled")

    fun apply(request: MutationRequest): MutationResult {
        if (request.property !in allowedProperties) {
            return MutationResult(
                applied = false,
                message = "property '${request.property}' is not in the mutation allowlist $allowedProperties",
            )
        }
        return runOnMainSync(handler) {
            val view = resolve(request.selector)
                ?: return@runOnMainSync MutationResult(
                    applied = false,
                    message = "no view matched selector ${request.selector.describe()}",
                )
            applyTo(view, request)
        } ?: MutationResult(applied = false, message = "mutation timed out on main thread")
    }

    private fun applyTo(view: View, request: MutationRequest): MutationResult {
        val ref = ReticleReflect.resourceEntryName(view) ?: view.javaClass.simpleName
        return when (request.property) {
            "alpha" -> {
                val previous = MetadataValue.Real(view.alpha.toDouble())
                view.alpha = request.value.asDouble()?.toFloat() ?: view.alpha
                MutationResult(applied = true, ref = ref, previousValue = previous)
            }

            "enabled" -> {
                val previous = MetadataValue.Bool(view.isEnabled)
                view.isEnabled = request.value.asBool() ?: view.isEnabled
                MutationResult(applied = true, ref = ref, previousValue = previous)
            }

            "visibility" -> {
                val previous = MetadataValue.Text(visibilityName(view.visibility))
                view.visibility = when (request.value.asString()) {
                    "visible" -> View.VISIBLE
                    "invisible" -> View.INVISIBLE
                    "gone" -> View.GONE
                    else -> view.visibility
                }
                MutationResult(applied = true, ref = ref, previousValue = previous)
            }

            "text" -> {
                if (view is TextView) {
                    val previous = MetadataValue.Text(view.text?.toString() ?: "")
                    view.text = request.value.asString() ?: view.text
                    MutationResult(applied = true, ref = ref, previousValue = previous)
                } else {
                    MutationResult(applied = false, ref = ref, message = "view is not a TextView")
                }
            }

            "backgroundColor" -> {
                val previous = ReticleReflect.backgroundColorHex(view)?.let { MetadataValue.Text(it) }
                val parsed = request.value.asString()?.let { runCatching { Color.parseColor(it) }.getOrNull() }
                if (parsed != null) {
                    view.setBackgroundColor(parsed)
                    MutationResult(applied = true, ref = ref, previousValue = previous)
                } else {
                    MutationResult(applied = false, ref = ref, message = "could not parse color")
                }
            }

            "textColor" -> {
                if (view is TextView) {
                    val previous = MetadataValue.Text(ReticleReflect.colorHex(view.currentTextColor))
                    val parsed = request.value.asString()?.let { runCatching { Color.parseColor(it) }.getOrNull() }
                    if (parsed != null) {
                        // setTextColor takes a single color, which also collapses
                        // any ColorStateList — fine for live diagnosis/iteration.
                        view.setTextColor(parsed)
                        MutationResult(applied = true, ref = ref, previousValue = previous)
                    } else {
                        MutationResult(applied = false, ref = ref, message = "could not parse color")
                    }
                } else {
                    MutationResult(applied = false, ref = ref, message = "view is not a TextView")
                }
            }

            "textSize" -> {
                if (view is TextView) {
                    val previous = MetadataValue.Real(view.textSize.toDouble())
                    val px = request.value.asDouble()?.toFloat()
                    if (px != null) {
                        // Value is in pixels (matches what the snapshot reports).
                        view.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, px)
                        MutationResult(applied = true, ref = ref, previousValue = previous)
                    } else {
                        MutationResult(applied = false, ref = ref, message = "textSize needs a number (px)")
                    }
                } else {
                    MutationResult(applied = false, ref = ref, message = "view is not a TextView")
                }
            }

            else -> MutationResult(applied = false, ref = ref, message = "unsupported property")
        }
    }

    /** testId/resource-id first, then ref, then point — the resolution order. */
    private fun resolve(selector: Selector): View? {
        val roots = ReticleWindows.rootViews()
        if (selector.testId != null || selector.resourceId != null) {
            // Topmost window first, matching the point fallback below: when a
            // dialog and its background activity both contain a match, the
            // visible (dialog) view must win for every selector type.
            for (root in roots.reversed()) {
                findIn(root, selector)?.let { return it }
            }
        }
        // ref: resolve against the same tree walk / ref numbering as capture, so
        // a ref taken from a snapshot maps back to the same View.
        selector.ref?.let { ref ->
            SnapshotCapture(context).viewByRef(ref)?.let { return it }
        }
        // Point fallback: deepest hit view at the coordinate.
        selector.point?.let { p ->
            for (root in roots.reversed()) {
                hitTest(root, p.x.toInt(), p.y.toInt())?.let { return it }
            }
        }
        return null
    }

    private fun findIn(view: View, selector: Selector): View? {
        val resName = ReticleReflect.resourceEntryName(view)
        val tag = ReticleReflect.testTag(view)
        if (selector.testId != null && selector.testId == tag) return view
        if (selector.resourceId != null && selector.resourceId == resName) return view
        if (view is android.view.ViewGroup) {
            for (i in 0 until view.childCount) {
                findIn(view.getChildAt(i), selector)?.let { return it }
            }
        }
        return null
    }

    private fun hitTest(view: View, x: Int, y: Int): View? {
        val loc = IntArray(2)
        view.getLocationOnScreen(loc)
        val withinX = x >= loc[0] && x <= loc[0] + view.width
        val withinY = y >= loc[1] && y <= loc[1] + view.height
        if (!withinX || !withinY) return null
        if (view is android.view.ViewGroup) {
            for (i in view.childCount - 1 downTo 0) {
                hitTest(view.getChildAt(i), x, y)?.let { return it }
            }
        }
        return view
    }

    private fun visibilityName(v: Int): String = when (v) {
        View.VISIBLE -> "visible"
        View.INVISIBLE -> "invisible"
        else -> "gone"
    }

}

private fun MetadataValue.asDouble(): Double? = when (this) {
    is MetadataValue.Real -> value
    is MetadataValue.Integer -> value.toDouble()
    is MetadataValue.Text -> value.toDoubleOrNull()
    else -> null
}

private fun MetadataValue.asBool(): Boolean? = when (this) {
    is MetadataValue.Bool -> value
    is MetadataValue.Text -> value.toBooleanStrictOrNull()
    else -> null
}

private fun MetadataValue.asString(): String? = when (this) {
    is MetadataValue.Text -> value
    else -> displayString()
}
