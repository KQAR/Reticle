package dev.reticle.core

import java.util.Locale
import kotlinx.serialization.Serializable

/**
 * Style observation: every node's geometry and style properties, each in the
 * units a consumer needs and each labelled with the channel it was read through.
 *
 * This is deliberately NOT a comparison. Reticle does not know what the values
 * ought to be — a design frame, a previous build and a second device are all
 * equally valid things to hold this up against, and the threshold and the
 * exemption list ("ignore the status bar") are the consumer's policy, not an
 * observation. So the projection stops at the magnitudes and their provenance;
 * whoever asked decides what counts as wrong.
 *
 * Two things it does do, because neither is guessable from the outside:
 *
 *  - **Units.** A raw length is meaningless without the screen it was measured
 *    on. Each length is rendered in device pixels, in density-independent units,
 *    and — for text — in scale-independent ones, so a consumer never has to infer
 *    what `density` meant on this platform. See [StyleUnit].
 *  - **Gaps.** A property Reticle cannot read is listed by name with a reason
 *    ([Node.styleGaps]) instead of being absent, so "the app sets no corner
 *    radius" and "this radius lives in a Compose draw modifier" stop looking
 *    identical.
 */
@Serializable
data class StyleObservation(
    val capturedAtMillis: Long,
    val platform: String,
    val screen: ScreenInfo,
    val items: List<StyleItem>,
    /**
     * How many style-bearing nodes past the projection cap were dropped. Zero
     * when everything fit; rendered so the cap never silently reads as "that was
     * every node" — the dropped nodes are still in the snapshot.
     */
    val truncatedItems: Int = 0,
) {
    /**
     * The whole text projection: screen header, then one block per node that has
     * style or a declared gap.
     *
     * It lives here rather than in each host renderer so the Kotlin helper and the
     * Swift host cannot render the same snapshot differently — the failure mode
     * this repo has already had twice. `style-observation.cases.json` pins the
     * output of exactly this function on both sides.
     */
    fun render(): String {
        val out = ArrayList<String>()
        out.add(screenLine())
        for (item in items) {
            if (!item.hasInformativeStyle()) continue
            out.add(item.headerLine())
            out.addAll(item.bodyLines())
        }
        if (out.size == 1) out.add("(no style-bearing nodes in this snapshot)")
        if (truncatedItems > 0) {
            out.add(
                "($truncatedItems more style-bearing node(s) beyond this projection's cap — " +
                    "NOT listed here; they are still in the snapshot)"
            )
        }
        return out.joinToString("\n")
    }

    /**
     * Screen header line: raw size, the divisors, and — where the raw unit is
     * physical pixels — the same size in dp. On iOS the raw unit already IS
     * density-independent, so no second figure is printed rather than printing
     * one number twice under two names.
     */
    fun screenLine(): String {
        val d = screen.density
        val rawUnit = if (StyleUnits.lengthsAreDensityIndependent(platform)) "pt" else "px"
        val dp = if (rawUnit == "px" && d > 0) {
            " -> ${fmt(screen.size.width / d)}x${fmt(screen.size.height / d)}dp"
        } else {
            ""
        }
        val scale = screen.fontScale?.let { " fontScale=${fmt(it)}" } ?: " fontScale=unprobed"
        return "screen: ${fmt(screen.size.width)}x${fmt(screen.size.height)}$rawUnit " +
            "density=${fmt(d)}$scale$dp"
    }

    companion object {
        /**
         * Build from a snapshot, keeping nodes that carry a frame, a style
         * property or a declared gap.
         *
         * Unlike [CompactObservation] this does NOT filter on
         * `hasTargetingSignal()` or visibility: an unlabelled spacer container is
         * exactly the kind of node a spacing question is about, and an invisible
         * one still has a specified style. The compact view is for acting now;
         * this one is for measuring.
         */
        fun from(snapshot: Snapshot, maxItems: Int = 500): StyleObservation {
            val units = StyleUnits(snapshot.platform, snapshot.screen)
            val items = ArrayList<StyleItem>()
            // Seen-set, aligned with the Swift twin (which already had one): a
            // children cycle in a malformed snapshot must not recurse forever,
            // and a subtree reachable under two parents emits its items once.
            val seen = HashSet<String>()
            fun visit(ref: String) {
                if (!seen.add(ref)) return
                val node = snapshot.nodes[ref] ?: return
                val attributes = node.styleChannels.entries
                    .mapNotNull { (name, channel) ->
                        val value = node.custom[name] ?: return@mapNotNull null
                        if (StyleUnits.isUninformativeDefault(name, value)) return@mapNotNull null
                        StyleAttribute(
                            name = name,
                            value = value,
                            unit = StyleUnits.unitOf(name),
                            channel = channel,
                            rendered = units.render(name, value),
                        )
                    }
                    .sortedBy { it.name }
                val gaps = node.styleGaps.entries.sortedBy { it.key }
                    .map { StyleGap(property = it.key, reason = it.value) }
                // Kept inclusively HERE: a layout container's frame with no style of
                // its own is still the raw material of a spacing measurement, and
                // [items] is the data. The readability filter belongs to the text
                // view — see [StyleItem.hasInformativeStyle].
                if (node.frame != null || attributes.isNotEmpty() || gaps.isNotEmpty()) {
                    items.add(
                        StyleItem(
                            ref = node.ref,
                            role = node.role ?: node.typeName,
                            testId = node.testId,
                            resourceId = node.resourceId,
                            label = node.text ?: node.contentDescription,
                            frame = node.frame,
                            frameRendered = node.frame?.let { units.renderFrame(it) },
                            attributes = attributes,
                            gaps = gaps,
                        )
                    )
                }
                node.children.forEach { visit(it) }
            }
            visit(snapshot.rootRef)
            val kept = items.take(maxItems)
            return StyleObservation(
                capturedAtMillis = snapshot.capturedAtMillis,
                platform = snapshot.platform,
                screen = snapshot.screen,
                items = kept,
                truncatedItems = items.size - kept.size,
            )
        }

        internal fun fmt(value: Double): String {
            // Locale.ROOT, always: a comma decimal separator would make the two
            // language implementations of this projection disagree on a French
            // machine, and the fixture pins one spelling.
            val rounded = String.format(Locale.ROOT, "%.1f", value)
            return if (rounded.endsWith(".0")) rounded.dropLast(2) else rounded
        }
    }
}

/** One node's geometry + style, as rendered for a text projection. */
@Serializable
data class StyleItem(
    val ref: String,
    val role: String,
    val testId: String? = null,
    val resourceId: String? = null,
    val label: String? = null,
    val frame: Rect? = null,
    /** Multi-unit rendering of [frame]; null when the node has no frame. */
    val frameRendered: String? = null,
    val attributes: List<StyleAttribute> = emptyList(),
    val gaps: List<StyleGap> = emptyList(),
) {
    /**
     * True when this node has something to say: a property off its platform
     * default, or a declared gap.
     *
     * The text projection skips the rest. An Android `ViewGroup` reports four
     * paddings and an elevation whether or not anyone set them, so wrappers with
     * nothing but zeros produced a seven-line block each and made the view
     * unreadable (measured on a real device, on the sample's own home screen). Note
     * what this is NOT: once a node is kept, ALL its properties print, zeros
     * included — "the app sets padding 0 and the design says 16" is exactly the
     * finding this projection exists to support. And [attributes] keeps everything
     * either way, so a structured consumer never sees this filter at all.
     */
    fun hasInformativeStyle(): Boolean =
        gaps.isNotEmpty() || attributes.any { !StyleUnits.isDefaultValued(it.name, it.value) }

    /** Header line for this node: selector, role, label. */
    fun headerLine(): String {
        val selector = testId?.let { "#$it" } ?: resourceId?.let { "@$it" } ?: ref
        val labelPart = label?.let { " \"${it.take(40)}\"" } ?: ""
        return "$selector $role$labelPart"
    }

    /** The indented body: frame, then each attribute, then each gap. */
    fun bodyLines(): List<String> {
        val out = ArrayList<String>(attributes.size + gaps.size + 1)
        frameRendered?.let { out.add("    frame  $it") }
        val width = attributes.maxOfOrNull { it.name.length } ?: 0
        attributes.forEach {
            out.add("    ${it.name.padEnd(width)}  ${it.rendered}  [${it.channel.name}]")
        }
        gaps.forEach { out.add("    ! ${it.property}  unreadable: ${it.reason}") }
        return out
    }
}

/** One style property: the raw value, its unit, its provenance, its rendering. */
@Serializable
data class StyleAttribute(
    val name: String,
    val value: MetadataValue,
    val unit: StyleUnit,
    val channel: StyleChannel,
    /** Human-facing multi-unit rendering, e.g. "42px | 14dp | 14sp". */
    val rendered: String,
)

/** A style property that exists on screen but which no channel can read. */
@Serializable
data class StyleGap(val property: String, val reason: String)

/**
 * What kind of quantity a style property holds — which decides whether a unit
 * conversion is meaningful at all.
 *
 * Only [length] and [textLength] are converted. Everything else is passed
 * through verbatim, including [opaque], which is the honest answer for a value
 * whose unit Reticle does not know (a `getComputedStyle` string carries its own
 * suffix and a page's zoom is not observable from here, so converting it would
 * be arithmetic on an assumption).
 */
@Serializable
enum class StyleUnit {
    /** A device length: rendered in px and dp. */
    length,

    /** A text length: rendered in px, dp AND sp, since font scaling applies. */
    textLength,

    /** An ARGB hex string. */
    color,

    /** A named constant (`center`, `italic`, `sans-serif`). */
    keyword,

    /** A unitless 0..1 fraction. */
    ratio,

    /** A unitless integer (font weight, line count). */
    count,

    /** Unit unknown to this table — passed through, never converted. */
    opaque,
}

/**
 * The property-name -> [StyleUnit] table plus the conversions.
 *
 * The table lives here rather than on the wire because the name already
 * determines the kind: emitting a unit tag per property would be a second copy
 * of this knowledge, free to drift from the first. Names not in the table render
 * as [StyleUnit.opaque] — new capture surfaces degrade to "shown verbatim"
 * instead of to a wrong conversion.
 */
class StyleUnits(private val platform: String, private val screen: ScreenInfo) {

    private val densityDivisor: Double
        get() = if (lengthsAreDensityIndependent(platform)) 1.0 else screen.density.takeIf { it > 0 } ?: 1.0

    /** Render one property value in every unit that applies to it. */
    fun render(name: String, value: MetadataValue): String = when (unitOf(name)) {
        StyleUnit.length -> lengths(value)
        StyleUnit.textLength -> textLengths(value)
        else -> value.displayString()
    }

    /** `24,1800 1032x120px | 8,600 344x40dp | 95.6%x5% of screen` */
    fun renderFrame(frame: Rect): String {
        val raw = rawUnit()
        val px = "${StyleObservation.fmt(frame.x)},${StyleObservation.fmt(frame.y)} " +
            "${StyleObservation.fmt(frame.width)}x${StyleObservation.fmt(frame.height)}$raw"
        val d = densityDivisor
        val dp = if (raw == "px") {
            " | ${StyleObservation.fmt(frame.x / d)},${StyleObservation.fmt(frame.y / d)} " +
                "${StyleObservation.fmt(frame.width / d)}x${StyleObservation.fmt(frame.height / d)}dp"
        } else {
            ""
        }
        val share = if (screen.size.width > 0 && screen.size.height > 0) {
            " | ${pct(frame.width / screen.size.width)}x${pct(frame.height / screen.size.height)} of screen"
        } else {
            ""
        }
        return px + dp + share
    }

    private fun rawUnit(): String = if (lengthsAreDensityIndependent(platform)) "pt" else "px"

    private fun lengths(value: MetadataValue): String {
        val raw = value.asDouble() ?: return value.displayString()
        val base = "${StyleObservation.fmt(raw)}${rawUnit()}"
        if (rawUnit() == "pt") return base
        return "$base | ${StyleObservation.fmt(raw / densityDivisor)}dp"
    }

    private fun textLengths(value: MetadataValue): String {
        val raw = value.asDouble() ?: return value.displayString()
        val base = lengths(value)
        // sp divides out font scaling as well as density, recovering the size the
        // app asked for. Unprobed font scale means the two cannot be told apart —
        // say so rather than printing dp twice under different names.
        val scale = screen.fontScale
            ?: return "$base | sp:unprobed (no fontScale in this capture)"
        if (scale <= 0) return base
        return "$base | ${StyleObservation.fmt(raw / densityDivisor / scale)}sp"
    }

    private fun pct(fraction: Double): String = "${StyleObservation.fmt(fraction * 100)}%"

    companion object {
        /**
         * True when this platform's view geometry is ALREADY density-independent,
         * so a px->dp division would scale it twice. UIKit measures in points; the
         * Android view tree measures in physical pixels.
         */
        fun lengthsAreDensityIndependent(platform: String): Boolean = platform == "ios"

        private val TABLE: Map<String, StyleUnit> = mapOf(
            "textSize" to StyleUnit.textLength,
            "lineHeight" to StyleUnit.textLength,
            "letterSpacing" to StyleUnit.textLength,
            "paddingLeft" to StyleUnit.length,
            "paddingTop" to StyleUnit.length,
            "paddingRight" to StyleUnit.length,
            "paddingBottom" to StyleUnit.length,
            "cornerRadius" to StyleUnit.length,
            "borderWidth" to StyleUnit.length,
            "elevation" to StyleUnit.length,
            "textColor" to StyleUnit.color,
            "backgroundColor" to StyleUnit.color,
            "borderColor" to StyleUnit.color,
            "tintColor" to StyleUnit.color,
            "linkTextColor" to StyleUnit.color,
            "textAlign" to StyleUnit.keyword,
            "fontFamily" to StyleUnit.keyword,
            "fontStyle" to StyleUnit.keyword,
            "visibility" to StyleUnit.keyword,
            "alpha" to StyleUnit.ratio,
            "fontWeight" to StyleUnit.count,
            "maxLines" to StyleUnit.count,
        )

        fun unitOf(name: String): StyleUnit = TABLE[name] ?: StyleUnit.opaque

        /**
         * True for the two properties every platform view carries at a value that
         * says nothing at all: full opacity and ordinary visibility. These are
         * dropped from the output entirely.
         *
         * Measured, not guessed at: on a real iOS screen these two turned a 40-node
         * capture into 120 lines of `alpha 1.0`, burying the handful of nodes that
         * had style of their own.
         */
        fun isUninformativeDefault(name: String, value: MetadataValue): Boolean = when {
            name == "alpha" -> value.asDouble() == 1.0
            name == "visibility" -> (value as? MetadataValue.Text)?.value == "visible"
            // `getComputedStyle` answers for EVERY property whether or not the page
            // stated it, so a computed value equal to the CSS initial value means
            // "not stated" — the DOM's exact analogue of a null Android background
            // or an absent iOS inset, both of which emit no key at all. Without
            // this one DOM node printed 26 lines of `auto` / `none` / `0px`
            // (measured on the sample's WebView page), which on a real page is
            // hundreds of lines that say nothing.
            name.startsWith("domStyle") ->
                (value as? MetadataValue.Text)?.value in CSS_INITIAL_VALUES
            else -> false
        }

        /**
         * Computed-style spellings that mean "the page did not state this".
         *
         * Deliberately value-based rather than per-property: the CSS initial value
         * for `display` depends on the element type, which is not knowable from a
         * property name, while these spellings mean the same thing everywhere. A
         * stated value that happens to look default-ish (`text-align: left`, weight
         * `400`) is NOT in here and stays visible — the same rule that keeps an
         * explicit `padding: 0`.
         *
         * What this deliberately does NOT do is suppress an INHERITED value because
         * an ancestor reports the same one. That would shrink the output further
         * (typography repeats down a DOM subtree) but it would break the main use
         * case: a design states "this button's label is 14px", and if the button
         * inherits 14px from `body` the node a consumer is asking about would show
         * nothing at all. Repetition is the lesser cost. Measured on the sample's
         * WebView page: 26 lines per node became 6, and 33 for the whole page.
         */
        private val CSS_INITIAL_VALUES = setOf(
            "none",
            "auto",
            "normal",
            "visible",
            "static",
            "0px",
            "1",
            "rgba(0, 0, 0, 0)",
        )

        /**
         * True when a property is sitting at its platform default, so it says
         * nothing **on its own** — every zero length included.
         *
         * This decides whether a NODE is worth printing, not whether a property is
         * worth printing, and the difference is the whole point. An Android
         * `ViewGroup` reports four paddings and an elevation whether or not anyone
         * set them, so a wrapper with nothing but zeros produced a seven-line block
         * per node and made the view unreadable (measured on a real device: the
         * sample's home screen). But once a node HAS style — a background, a text
         * size — its zeros become informative, because "the app sets padding 0 and
         * the design says 16" is exactly the finding this projection exists to
         * support. So a node is kept when any property is off its default, and a
         * kept node prints all of them, zeros and all.
         *
         * A declared gap also keeps a node, unconditionally: an unreadable property
         * is a fact about that node even when nothing else on it is set. And
         * nothing is lost in any case — `custom` still carries every value for
         * `ui node`.
         */
        fun isDefaultValued(name: String, value: MetadataValue): Boolean {
            if (isUninformativeDefault(name, value)) return true
            return when (unitOf(name)) {
                StyleUnit.length, StyleUnit.textLength -> value.asDouble() == 0.0
                StyleUnit.count -> value.asDouble() == 0.0
                else -> false
            }
        }
    }
}

private fun MetadataValue.asDouble(): Double? = when (this) {
    is MetadataValue.Real -> value
    is MetadataValue.Integer -> value.toDouble()
    else -> null
}
