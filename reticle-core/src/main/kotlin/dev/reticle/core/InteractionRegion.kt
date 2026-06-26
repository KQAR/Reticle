package dev.reticle.core

import kotlinx.serialization.Serializable

/**
 * Sub-node interaction evidence. This is the answer to "a single View carries
 * more than one tappable region" — the case the plain view tree and the
 * semantic tree both collapse into one node.
 *
 * This is driven by a concrete finding on a real app (a custom MarkdownCheckBox
 * whose "toggle" vs "open agreement" regions live only inside its private
 * onTouchEvent). The design principle: surface only what is recoverable through
 * documented runtime mechanisms, and HONESTLY mark the rest as a hint rather
 * than inventing coordinates.
 *
 * Three discovery channels, in descending reliability:
 *
 *   1. SPAN         — ClickableSpan / URLSpan ranges in a Spanned text, with
 *                     pixel hit-rects computed from the View's Layout. Reliable.
 *   2. A11Y_VIRTUAL — virtual accessibility sub-nodes exposed via
 *                     getAccessibilityNodeProvider() (ExploreByTouchHelper).
 *                     The official way to expose multiple regions in one View.
 *   3. TOUCH_DELEGATE — an extended/forwarded hit-rect via getTouchDelegate().
 *
 * When none of the above resolve but the node still looks multi-region (an
 * interactive TextView whose text contains paired-bracket / markdown link
 * markers, no children, no spans), the node is flagged
 * `suspectedMultiRegion = true` and a CHAR_GRID is attached so an agent can
 * target a substring by coordinate.
 */
@Serializable
enum class RegionSource {
    span,
    a11yVirtual,
    touchDelegate,

    /**
     * Heuristic: an in-text link marker (《…》 or markdown `[text](url)`) whose
     * rect was computed from the View's Layout, when the control exposed no
     * real ClickableSpan / virtual node (e.g. a self-drawn control that parses
     * markup and hit-tests privately). The rect is reliable geometry; the
     * "this is a link" inference is a guess — pair with `suspectedMultiRegion`.
     */
    textMarker,

    /**
     * Heuristic: a contiguous run colored differently from the node's base text
     * color, found via a ForegroundColorSpan range. A re-colored run that isn't
     * a real ClickableSpan is the classic "looks like a link" signal apps use
     * (color the phrase, hit-test it manually in one OnClickListener). Reliable
     * geometry + the actual color; the "is a link" inference is a guess.
     */
    colorSpan,
}

@Serializable
data class InteractionRegion(
    val source: RegionSource,
    /** The text covered by this region, when known. */
    val label: String? = null,
    /** Navigation/link target for URLSpan, when present. */
    val target: String? = null,
    /** Character range [start, end) within the node's text, when span-derived. */
    val charStart: Int? = null,
    val charEnd: Int? = null,
    /**
     * Screen-space hit rectangles. A span that wraps across lines yields more
     * than one rect, so this is a list, never silently truncated to one.
     */
    val rects: List<Rect> = emptyList(),
    /**
     * Text color of this run as #AARRGGBB, when it differs from the node's base
     * text color (i.e. a deliberately highlighted run — the typical link tint).
     * Present for `colorSpan`, and for `span` when a ForegroundColorSpan or the
     * link text color applies. Null when the run uses the base color.
     */
    val color: String? = null,
) {
    /** Best single tap point for this region: center of the first rect. */
    fun tapPoint(): Point? = rects.firstOrNull()?.let { Point(it.centerX, it.centerY) }
}

/**
 * Character-position grid for a text node. Lets an agent map a screen X (on a
 * given line) to a character offset and back, so it can target a substring
 * (e.g. a bracketed agreement link) even when the widget exposes no spans and
 * no virtual nodes — the only thing recoverable for a fully self-drawn control.
 *
 * Derived from android.text.Layout, which is the same geometry the framework
 * uses to draw text, so it is accurate for the common single-line/LTR case and
 * honestly degrades (see `approximate`) for wrapped/BiDi text.
 */
@Serializable
data class CharGrid(
    val text: String,
    val lines: List<CharLine>,
    /** True when geometry could not be computed exactly (BiDi, missing layout). */
    val approximate: Boolean = false,
) {
    /** Screen rect covering character range [start, end) on its line(s). */
    fun rangeRects(start: Int, end: Int): List<Rect> =
        lines.mapNotNull { it.subRange(start, end) }
}

@Serializable
data class CharLine(
    val line: Int,
    /** Character offset range covered by this visual line: [start, end). */
    val start: Int,
    val end: Int,
    /**
     * Top/bottom screen Y of the line box. Taken from Layout.getLineTop/
     * getLineBottom, which already fold in font ascent/descent, line-spacing
     * extra, and line-spacing multiplier — so these are correct for any font,
     * size, or spacing without Reticle re-deriving anything.
     */
    val top: Double,
    val bottom: Double,
    /**
     * Real screen X at each character boundary on this line, length
     * `(end - start) + 1`. `xOffsets[i]` is the left edge of character
     * `(start + i)`, and the final entry is the right edge of the last
     * character. Sourced per-offset from Layout.getPrimaryHorizontal, i.e. the
     * exact laid-out glyph positions — NOT an equal-width interpolation — so it
     * is accurate for proportional fonts and mixed CJK/Latin/emoji runs.
     */
    val xOffsets: List<Double>,
) {
    /** The rect for the intersection of [a, b) with this line, or null. */
    fun subRange(a: Int, b: Int): Rect? {
        val s = maxOf(a, start)
        val e = minOf(b, end)
        if (s >= e || xOffsets.size < 2) return null
        val i0 = (s - start).coerceIn(0, xOffsets.size - 1)
        val i1 = (e - start).coerceIn(0, xOffsets.size - 1)
        val lo = xOffsets[i0]
        val hi = xOffsets[i1]
        return Rect(x = minOf(lo, hi), y = top, width = kotlin.math.abs(hi - lo), height = bottom - top)
    }
}
