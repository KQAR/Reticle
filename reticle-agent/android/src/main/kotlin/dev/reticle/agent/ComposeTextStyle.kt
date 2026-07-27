package dev.reticle.agent

import dev.reticle.core.MetadataValue
import dev.reticle.core.StyleChannel

/**
 * Text style of a Compose `Text`, recovered from the `TextLayoutResult` the
 * semantics tree already hands out.
 *
 * Why this exists: a `composeSemantics` node carried NO style at all. Semantics
 * is an accessibility surface — it answers "what is this and what can I do to
 * it", never "what size is the type" — so on a Compose screen every question a
 * design asks (font size, weight, colour, line height, alignment) had no answer,
 * while the identical `TextView` screen answered all of them. Since Compose is
 * where new Android UI is written, that asymmetry made the whole style surface
 * close to useless in practice.
 *
 * The channel is the one `ComposeTextRegions` already uses:
 * `SemanticsActions.GetTextLayoutResult` — the action TalkBack invokes — whose
 * `TextLayoutResult.layoutInput.style` is the `TextStyle` the text was laid out
 * with. Public API, reached reflectively so the agent keeps its `compileOnly`
 * Compose dependency, and every step fails closed.
 *
 * Two mechanical details make the reflection work:
 *
 *  - **Mangled names.** `TextStyle.getFontSize()` returns `TextUnit`, an inline
 *    value class, so its JVM name may carry a `-XSAIIZE`-style suffix. Reads go
 *    through [ReticleReflect.invokeNoArgByPrefix].
 *  - **Unboxed value classes.** A non-null `TextUnit`/`Color` getter returns the
 *    packed primitive, not an object, so there is nothing to call methods on. The
 *    static `…-impl` helpers on the value class itself unpack them.
 *
 * Units are normalised to match the `TextView` path exactly: lengths come out as
 * rendered device pixels, so `textSize` means the same thing on both channels and
 * a consumer never has to ask which kind of node it is holding.
 */
object ComposeTextStyle {

    data class Result(
        val values: Map<String, MetadataValue>,
        val channels: Map<String, StyleChannel>,
        val gaps: Map<String, String>,
    ) {
        companion object {
            val EMPTY = Result(emptyMap(), emptyMap(), emptyMap())
        }
    }

    /**
     * [densityScale] is `Configuration.densityDpi / 160`, [fontScale] the system
     * font scale: an sp value renders at `sp * densityScale * fontScale` px, the
     * figure `TextView.getTextSize()` reports for the same text.
     */
    fun probe(semanticsNode: Any, densityScale: Float, fontScale: Float): Result {
        val layout = SemanticsReflect.textLayoutResult(semanticsNode) ?: return Result.EMPTY
        val input = ReticleReflect.invokeNoArgByPrefix(layout, "getLayoutInput") ?: return Result.EMPTY
        val style = ReticleReflect.invokeNoArgByPrefix(input, "getStyle")
            ?: return Result(
                emptyMap(),
                emptyMap(),
                // The layout result IS there, so this text certainly has a style;
                // failing to read it is a gap, not an absence.
                mapOf("textSize" to "compose-textstyle-unreadable"),
            )

        val values = LinkedHashMap<String, MetadataValue>()
        val channels = LinkedHashMap<String, StyleChannel>()
        val gaps = LinkedHashMap<String, String>()

        fun put(name: String, value: MetadataValue) {
            values[name] = value
            channels[name] = StyleChannel.textLayout
        }

        // fontSize first: an Em-typed letterSpacing or lineHeight is relative to it.
        val fontSizePx = textUnitPx(
            ReticleReflect.invokeNoArgByPrefix(style, "getFontSize"),
            densityScale = densityScale,
            fontScale = fontScale,
            relativeToPx = null,
        )
        if (fontSizePx != null) {
            put("textSize", MetadataValue.Real(fontSizePx.toDouble()))
        } else {
            gaps["textSize"] = "compose-textunit-unreadable"
        }

        textUnitPx(
            ReticleReflect.invokeNoArgByPrefix(style, "getLineHeight"),
            densityScale, fontScale, relativeToPx = fontSizePx,
        )?.let { put("lineHeight", MetadataValue.Real(it.toDouble())) }

        textUnitPx(
            ReticleReflect.invokeNoArgByPrefix(style, "getLetterSpacing"),
            densityScale, fontScale, relativeToPx = fontSizePx,
        )?.let { put("letterSpacing", MetadataValue.Real(it.toDouble())) }

        colorHex(ReticleReflect.invokeNoArgByPrefix(style, "getColor"))?.let {
            put("textColor", MetadataValue.Text(it))
        }

        // FontWeight is an ordinary class: weight is a plain Int.
        ReticleReflect.invokeNoArgByPrefix(style, "getFontWeight")
            ?.let { ReticleReflect.invokeNoArg(it, "getWeight") as? Int }
            ?.let { put("fontWeight", MetadataValue.Integer(it.toLong())) }

        // FontStyle / TextAlign / FontFamily are nullable, so they arrive boxed and
        // their toString() is the authored name ("Italic", "Center", the family).
        keyword(ReticleReflect.invokeNoArgByPrefix(style, "getFontStyle"))?.let {
            put("fontStyle", MetadataValue.Text(it.lowercase()))
        }
        keyword(ReticleReflect.invokeNoArgByPrefix(style, "getTextAlign"))?.let {
            put("textAlign", MetadataValue.Text(it.lowercase()))
        }
        keyword(ReticleReflect.invokeNoArgByPrefix(style, "getFontFamily"))?.let {
            put("fontFamily", MetadataValue.Text(it))
        }

        return Result(values, channels, gaps)
    }

    /**
     * Unpack a `TextUnit` to rendered device pixels. `Sp` scales by density and
     * font scale; `Em` is a multiple of [relativeToPx]; `Unspecified` (and anything
     * unrecognised) yields null rather than a guessed zero.
     */
    private fun textUnitPx(
        packed: Any?,
        densityScale: Float,
        fontScale: Float,
        relativeToPx: Float?,
    ): Float? {
        val raw = (packed as? Number)?.toLong() ?: return null
        val cls = textUnitClass ?: return null
        val value = try {
            val method = cls.methods.firstOrNull {
                it.name.startsWith("getValue-impl") && it.parameterTypes.size == 1
            } ?: return null
            (method.invoke(null, raw) as? Number)?.toFloat() ?: return null
        } catch (_: Throwable) {
            return null
        }
        if (value.isNaN()) return null
        return when (unitTag(cls, raw)) {
            "sp" -> value * densityScale * fontScale
            "em" -> relativeToPx?.let { value * it }
            else -> null
        }
    }

    /**
     * Which unit a packed `TextUnit` carries. `TextUnit.toString-impl` renders
     * "14.0.sp" / "1.5.em" / "Unspecified", so the suffix is the tag — read from
     * the value class's own rendering rather than from a copy of its bit layout,
     * which is not public API.
     */
    private fun unitTag(cls: Class<*>, packed: Long): String? {
        return try {
            val method = cls.methods.firstOrNull {
                it.name.startsWith("toString-impl") && it.parameterTypes.size == 1
            } ?: return null
            val rendered = method.invoke(null, packed) as? String ?: return null
            when {
                rendered.endsWith(".sp") -> "sp"
                rendered.endsWith(".em") -> "em"
                else -> null
            }
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * A packed `Color` (a ULong-backed value class) as `#AARRGGBB`.
     * `ColorKt.toArgb` takes the value class, so its JVM name is mangled and it is
     * found by prefix among the static methods.
     */
    private fun colorHex(packed: Any?): String? {
        val raw = (packed as? Number)?.toLong() ?: return null
        return try {
            val cls = Class.forName("androidx.compose.ui.graphics.ColorKt")
            val method = cls.methods.firstOrNull {
                it.name.startsWith("toArgb") && it.parameterTypes.size == 1
            } ?: return null
            val argb = (method.invoke(null, raw) as? Number)?.toInt() ?: return null
            // A fully transparent colour here means "unspecified", not "invisible
            // text": Compose's Color.Unspecified packs to 0 and the real colour is
            // resolved later from the local content colour, which is not on this
            // style.
            if (argb == 0) null else ReticleReflect.colorHex(argb)
        } catch (_: Throwable) {
            null
        }
    }

    /** `toString()` of a boxed Compose enum-like value, or null when absent. */
    private fun keyword(value: Any?): String? {
        val text = value?.toString()?.trim() ?: return null
        if (text.isEmpty() || text == "Unspecified" || text == "null") return null
        return text
    }

    private val textUnitClass: Class<*>? by lazy {
        try {
            Class.forName("androidx.compose.ui.unit.TextUnit")
        } catch (_: Throwable) {
            null
        }
    }
}
