package dev.reticle.agent

import android.graphics.drawable.ColorDrawable
import android.view.View
import java.lang.reflect.Method
import java.util.concurrent.ConcurrentHashMap

/**
 * Small reflection/inspection helpers for reading stable selectors and scalar
 * style off a View, turning views into scalar custom properties.
 */
object ReticleReflect {

    /**
     * Cache of resolved methods keyed by (declaring class, lookup key).
     * `getMethods()` clones the class's whole Method array on every call, and
     * these helpers run on the main thread — several times per View
     * ([shapeMetrics]) and per Compose text node ([ComposeTextStyle]) per
     * snapshot. Absent methods are cached too ([MISSING]), so a runtime whose
     * shape doesn't match never rescans either.
     */
    private val methodCache = ConcurrentHashMap<String, Any>()
    private val MISSING = Any()

    /**
     * Resolve a method on [target]'s class once, via [find] on a miss. [key]
     * must encode everything [find] matches on (name, arity, prefix marker).
     */
    internal fun cachedMethod(target: Any, key: String, find: (Class<*>) -> Method?): Method? {
        val cls = target.javaClass
        val cacheKey = "${cls.name}#$key"
        methodCache[cacheKey]?.let { return it as? Method }
        val m = find(cls)
        methodCache[cacheKey] = m ?: MISSING
        return m
    }

    /**
     * Call a public no-arg method by name, or null if it isn't there / throws.
     * Used to read Compose value types (AnnotatedString ranges, link
     * annotations) without a compile-time dependency on them.
     */
    fun invokeNoArg(target: Any, name: String): Any? {
        return try {
            cachedMethod(target, name) { cls ->
                cls.methods.firstOrNull { it.name == name && it.parameterTypes.isEmpty() }
            }?.invoke(target)
        } catch (_: Throwable) {
            null
        }
    }

    /** Android resource-id entry name, e.g. R.id.checkout_pay_button -> "checkout_pay_button". */
    fun resourceEntryName(view: View): String? {
        val id = view.id
        if (id == View.NO_ID) return null
        return try {
            val res = view.resources ?: return null
            if (id <= 0) return null
            res.getResourceEntryName(id)
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Compose testTag set on a View, or a View tag used as a stable id.
     * Compose's AndroidComposeView does not put testTags on Views; those are
     * read by ComposeSemanticsBridge. This covers the classic-View testTag
     * convention (view.tag as a String id) used by many apps.
     */
    fun testTag(view: View): String? {
        val tag = view.tag
        if (tag is String && tag.isNotBlank()) return tag
        return null
    }

    /**
     * React Native's `nativeID` prop. RN stores it as a *keyed* tag —
     * `view.setTag(R.id.view_tag_native_id, value)` — so it is invisible to the
     * keyless [testTag] read (RN's `testID` also writes the keyless tag; this
     * covers the nativeID-only case). The R.id constant lives in RN's resources,
     * so resolve it by name at runtime; 0 means RN isn't in this app.
     */
    fun nativeId(view: View): String? {
        return try {
            val context = view.context ?: return null
            val resId = nativeIdResource.getOrPut(context.packageName) {
                context.resources.getIdentifier("view_tag_native_id", "id", context.packageName)
            }
            if (resId == 0) return null
            val tag = view.getTag(resId)
            if (tag is String && tag.isNotBlank()) tag else null
        } catch (_: Throwable) {
            null
        }
    }

    /** package name -> resolved view_tag_native_id resource (0 = absent). */
    private val nativeIdResource = HashMap<String, Int>()

    fun backgroundColorHex(view: View): String? {
        val bg = view.background
        if (bg is ColorDrawable) return colorHex(bg.color)
        return null
    }

    fun colorHex(color: Int): String =
        String.format("#%08X", color)

    /**
     * Call a public no-arg method whose name is `prefix` or `prefix-<hash>`.
     *
     * Kotlin mangles the JVM name of a function whose signature involves an inline
     * value class (`Dp`, `TextUnit`, `Color`), so `getFontSize` can be on the class
     * as `getFontSize-XSAIIZE`. Matching by prefix reads the same public API
     * without hard-coding a mangling that differs between Compose builds.
     */
    fun invokeNoArgByPrefix(target: Any, prefix: String): Any? {
        return try {
            // "$prefix-*" keeps the prefix lookups in a namespace of their own,
            // so "getFontSize" by prefix and by exact name never collide.
            cachedMethod(target, "$prefix-*") { cls ->
                cls.methods
                    .filter { it.parameterTypes.isEmpty() && isPrefixMatch(it.name, prefix) }
                    // A property can present SEVERAL no-arg methods under one prefix,
                    // and picking the wrong one silently reads nothing. Measured on
                    // Compose 1.7.5's `TextStyle.textAlign`, which compiles to three:
                    //
                    //   getTextAlign-buA522U$annotations -> void
                    //   getTextAlign-e0LSkKk            -> int    (the packed value)
                    //   getTextAlign-buA522U            -> TextAlign
                    //
                    // `$annotations` is a synthetic Kotlin stub that returns void, so
                    // reading it yields null — and `Class.getMethods()` has NO ordered
                    // contract, so which one won varied between JVM runs. That is the
                    // worst failure this file can have: a style property that reads
                    // correctly on one run and is absent on the next.
                    //
                    // Drop the ones that cannot be a value (void, synthetic, bridge,
                    // and anything carrying `$`, which is a compiler-generated name),
                    // then order the rest so the choice is DETERMINISTIC: the PACKED
                    // (primitive) form first, because that is what this file's callers
                    // are written against — `ComposeTextStyle` unpacks a `TextUnit` /
                    // `Color` through the value class's own `…-impl` statics and has
                    // nothing to call on a boxed one — and the name as the tiebreak.
                    .filter { it.returnType != Void.TYPE && !it.isSynthetic && !it.isBridge }
                    .filterNot { it.name.contains('$') }
                    .minWithOrNull(
                        compareBy({ if (it.returnType.isPrimitive) 0 else 1 }, { it.name })
                    )
            }?.invoke(target)
        } catch (_: Throwable) {
            null
        }
    }

    private fun isPrefixMatch(name: String, prefix: String): Boolean =
        name == prefix || name.startsWith("$prefix-")

    /**
     * Shape metrics of a View's background: corner radius, stroke width, stroke
     * colour — the properties a design specifies and no `View` getter exposes.
     *
     * Read through PUBLIC getters only, on whichever drawable is actually there:
     * `GradientDrawable.getCornerRadius()` for an XML `<shape>`, and Material's
     * `MaterialShapeDrawable.getStrokeWidth()` / `getStrokeColor()` /
     * `getShapeAppearanceModel()` for a Material component. A `RippleDrawable` or
     * `InsetDrawable` wrapper is unwrapped first, since a Material button's real
     * background usually sits one layer down.
     *
     * No private-field reflection: `GradientDrawable`'s stroke lives in a hidden
     * `GradientState` field, and reading it would be a value that cannot be
     * verified against a public contract. Where a value is known to EXIST but is
     * shaped so it cannot be read as a length (a `RelativeCornerSize` is a
     * fraction of a rect this call does not have), the caller records a gap
     * instead — see [ShapeMetrics.cornerRadiusGap].
     */
    data class ShapeMetrics(
        val cornerRadiusPx: Float? = null,
        val cornerRadiusGap: String? = null,
        val strokeWidthPx: Float? = null,
        val strokeColorHex: String? = null,
        val fillColorHex: String? = null,
    ) {
        val isEmpty: Boolean
            get() = cornerRadiusPx == null && cornerRadiusGap == null &&
                strokeWidthPx == null && strokeColorHex == null && fillColorHex == null

        companion object {
            val EMPTY = ShapeMetrics()
        }
    }

    fun shapeMetrics(view: View): ShapeMetrics {
        val drawable = unwrapBackground(view.background) ?: return ShapeMetrics.EMPTY
        var radius: Float? = null
        var radiusGap: String? = null
        if (drawable is android.graphics.drawable.GradientDrawable) {
            // A per-corner radii array is a REAL shape with four different radii, and
            // one number cannot carry it — so it is a named gap, not an absence.
            //
            // Detected via `getCornerRadii()` (API 24+, non-null exactly when the
            // radii were set per corner) rather than by a negative `getCornerRadius()`:
            // that sentinel does not exist. `GradientDrawableState.setCornerRadii`
            // leaves `mRadius` at whatever it was — 0 for a drawable that never set a
            // uniform radius — so a per-corner shape used to report `cornerRadius = 0`,
            // i.e. "square corners", which is a confidently wrong reading of an 8px
            // rounded button. Measured under Robolectric in `ReticleReflectTest`.
            val perCorner = runCatching { drawable.cornerRadii }.getOrNull()
            if (perCorner != null) {
                radiusGap = "gradient-drawable-per-corner-radii"
            } else {
                radius = runCatching { drawable.cornerRadius }.getOrNull()?.takeIf { it >= 0f }
                if (radius == null) radiusGap = "gradient-drawable-per-corner-radii"
            }
        } else {
            val model = invokeNoArg(drawable, "getShapeAppearanceModel")
            val corner = model?.let { invokeNoArg(it, "getTopLeftCornerSize") }
            if (corner != null) {
                // AbsoluteCornerSize exposes a no-arg getCornerSize(); a
                // RelativeCornerSize only answers against a RectF, so it is a gap.
                radius = (invokeNoArg(corner, "getCornerSize") as? Number)?.toFloat()
                if (radius == null) radiusGap = "relative-corner-size-needs-bounds"
            }
        }
        val stroke = (invokeNoArg(drawable, "getStrokeWidth") as? Number)?.toFloat()
        val strokeColor = colorStateListHex(invokeNoArg(drawable, "getStrokeColor"))
        val fill = colorStateListHex(invokeNoArg(drawable, "getFillColor"))
            ?: colorStateListHex(invokeNoArg(drawable, "getColor"))
        return ShapeMetrics(
            cornerRadiusPx = radius,
            cornerRadiusGap = radiusGap,
            strokeWidthPx = stroke,
            strokeColorHex = strokeColor,
            fillColorHex = fill,
        )
    }

    /** A `ColorStateList`'s (or plain Integer's) default colour as hex. */
    private fun colorStateListHex(value: Any?): String? = when (value) {
        null -> null
        is android.content.res.ColorStateList -> colorHex(value.defaultColor)
        is Int -> colorHex(value)
        else -> null
    }

    /**
     * Peel `RippleDrawable` / `InsetDrawable` / `LayerDrawable` wrappers down to
     * the drawable that actually carries the shape. Bounded to a few levels — a
     * cyclic or pathological stack must not spin the capture.
     */
    private fun unwrapBackground(root: android.graphics.drawable.Drawable?): android.graphics.drawable.Drawable? {
        var current = root ?: return null
        repeat(4) {
            val next = when (current) {
                is android.graphics.drawable.InsetDrawable -> current.drawable
                is android.graphics.drawable.RippleDrawable -> {
                    val layers = current as android.graphics.drawable.LayerDrawable
                    (0 until layers.numberOfLayers)
                        .mapNotNull { i -> layers.getDrawable(i) }
                        .firstOrNull { it is android.graphics.drawable.GradientDrawable }
                }
                else -> null
            } ?: return current
            current = next
        }
        return current
    }
}
