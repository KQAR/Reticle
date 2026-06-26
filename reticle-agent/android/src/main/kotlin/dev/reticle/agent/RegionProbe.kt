package dev.reticle.agent

import android.graphics.Rect as AndroidRect
import android.text.Layout
import android.text.Spanned
import android.text.style.ClickableSpan
import android.text.style.URLSpan
import android.view.View
import android.widget.TextView
import dev.reticle.core.CharGrid
import dev.reticle.core.CharLine
import dev.reticle.core.InteractionRegion
import dev.reticle.core.Rect
import dev.reticle.core.RegionSource

/**
 * Discovers sub-regions inside a single View. This is the in-process
 * implementation of the channels validated by hand (via Frida) against a real
 * app: the same ART calls — Spanned.getSpans / Layout geometry,
 * getAccessibilityNodeProvider, getTouchDelegate.
 *
 * Runs on the main thread (called from SnapshotCapture, already on main).
 * Every channel degrades to "nothing" on any error rather than throwing, so a
 * weird widget never breaks a whole snapshot.
 */
object RegionProbe {

    data class Result(
        val regions: List<InteractionRegion>,
        val suspectedMultiRegion: Boolean,
        val charGrid: CharGrid?,
    )

    val EMPTY = Result(emptyList(), false, null)

    fun probe(view: View): Result {
        val regions = ArrayList<InteractionRegion>()

        // Channel 1: ClickableSpan / URLSpan ranges with pixel rects.
        if (view is TextView) {
            regions.addAll(spanRegions(view))
        }

        // Channel 2: virtual a11y sub-nodes (ExploreByTouchHelper et al).
        regions.addAll(virtualA11yRegions(view))

        // Channel 3: a forwarded/extended touch-delegate rect.
        touchDelegateRegion(view)?.let { regions.add(it) }

        // Channel 3b: re-colored runs (ForegroundColorSpan) that aren't already
        // covered by a real ClickableSpan — the "highlighted phrase = link"
        // signal apps use when they hit-test a single OnClickListener manually.
        if (view is TextView) {
            regions.addAll(colorSpanRegions(view, existing = regions))
        }

        // Suspected-multi-region heuristic: an interactive text node that looks
        // like it embeds links (paired bracket markers or a markdown link) yet
        // exposed no real spans, no virtual nodes, and has no child views.
        val standardChannelsEmpty = regions.isEmpty()
        val suspected = standardChannelsEmpty &&
            view is TextView &&
            (view.isClickable || view.isLongClickable) &&
            looksLikeEmbeddedLink(view.text?.toString()) &&
            (view !is android.view.ViewGroup || view.childCount == 0)

        // Channel 4 (fallback): for that self-drawn case, emit one region per
        // in-text marker so a multi-link row resolves to distinct targets
        // rather than a single collapsed block.
        if (suspected && view is TextView) {
            regions.addAll(markerRegions(view))
        }

        // Char grid for any text node (enables substring targeting even when no
        // markers were detected — the last resort for a self-drawn control).
        val grid = if (view is TextView) charGrid(view) else null

        if (regions.isEmpty() && grid == null && !suspected) return EMPTY
        return Result(regions, suspected, grid)
    }

    // --- Channel 1: spans -------------------------------------------------

    private fun spanRegions(tv: TextView): List<InteractionRegion> {
        val cs = tv.text ?: return emptyList()
        if (cs !is Spanned) return emptyList()
        val spans = cs.getSpans(0, cs.length, ClickableSpan::class.java)
        if (spans.isEmpty()) return emptyList()

        // The tint a ClickableSpan renders with unless a ForegroundColorSpan
        // overrides it — i.e. android:textColorLink. This is the link color
        // even though it lives on the View, not in the span.
        val linkColor = runCatching { tv.linkTextColors?.defaultColor }.getOrNull()

        val out = ArrayList<InteractionRegion>(spans.size)
        for (span in spans) {
            val start = cs.getSpanStart(span)
            val end = cs.getSpanEnd(span)
            val label = cs.subSequence(start.coerceAtLeast(0), end.coerceAtMost(cs.length)).toString()
            // A ForegroundColorSpan on the same range wins over the link color.
            val fg = foregroundColorOf(cs, start, end)
            val color = fg ?: linkColor
            out.add(
                InteractionRegion(
                    source = RegionSource.span,
                    label = label,
                    target = (span as? URLSpan)?.url,
                    charStart = start,
                    charEnd = end,
                    rects = rectsForRange(tv, start, end),
                    color = color?.let { ReticleReflect.colorHex(it) },
                )
            )
        }
        return out
    }

    /**
     * Channel 3b: contiguous runs colored by a ForegroundColorSpan that are NOT
     * already inside a discovered ClickableSpan region. A re-colored phrase with
     * no real span is the classic "highlight = tappable" pattern (app colors the
     * phrase and hit-tests it in a single OnClickListener). We surface it as a
     * candidate region with the actual color so an agent can decide.
     */
    private fun colorSpanRegions(tv: TextView, existing: List<InteractionRegion>): List<InteractionRegion> {
        val cs = tv.text ?: return emptyList()
        if (cs !is Spanned) return emptyList()
        val colorSpans = cs.getSpans(0, cs.length, android.text.style.ForegroundColorSpan::class.java)
        if (colorSpans.isEmpty()) return emptyList()

        val out = ArrayList<InteractionRegion>()
        for (span in colorSpans) {
            val start = cs.getSpanStart(span)
            val end = cs.getSpanEnd(span)
            if (end <= start) continue
            // Skip ranges already covered by a real span region.
            val covered = existing.any {
                val cs0 = it.charStart
                val ce0 = it.charEnd
                it.source == RegionSource.span && cs0 != null && ce0 != null &&
                    start >= cs0 && end <= ce0
            }
            if (covered) continue
            val label = cs.subSequence(start.coerceAtLeast(0), end.coerceAtMost(cs.length)).toString()
            out.add(
                InteractionRegion(
                    source = RegionSource.colorSpan,
                    label = label,
                    charStart = start,
                    charEnd = end,
                    rects = rectsForRange(tv, start, end),
                    color = ReticleReflect.colorHex(span.foregroundColor),
                )
            )
        }
        return out
    }

    /** The ForegroundColorSpan color covering [start,end), or null if none/partial. */
    private fun foregroundColorOf(cs: Spanned, start: Int, end: Int): Int? {
        val spans = cs.getSpans(start, end, android.text.style.ForegroundColorSpan::class.java)
        // Use a span that covers the whole range.
        for (s in spans) {
            if (cs.getSpanStart(s) <= start && cs.getSpanEnd(s) >= end) return s.foregroundColor
        }
        return null
    }

    /**
     * Per-line screen rects for the character range [start, end). Shared by the
     * span channel and the text-marker channel. A range wrapping across lines
     * yields one rect per line — never collapsed to a single block (the bug a
     * real three-link agreement row exposed).
     */
    private fun rectsForRange(tv: TextView, start: Int, end: Int): List<Rect> {
        val layout = tv.layout ?: return emptyList()
        val len = tv.text?.length ?: 0
        if (start !in 0..len || end !in 0..len || end <= start) return emptyList()
        val loc = IntArray(2)
        tv.getLocationOnScreen(loc)
        val padL = tv.totalPaddingLeft
        val padT = tv.totalPaddingTop
        val sx = tv.scrollX
        val sy = tv.scrollY
        val rects = ArrayList<Rect>()
        val lineStart = layout.getLineForOffset(start)
        // Use the last character actually in the range to pick the end line, so
        // a range ending exactly at a soft line break does NOT spill onto the
        // next line (the bug a wrapped multi-link agreement row exposed).
        val lineEnd = layout.getLineForOffset((end - 1).coerceAtLeast(start))
        for (ln in lineStart..lineEnd) {
            val lineCharStart = layout.getLineStart(ln)
            val lineCharEnd = layout.getLineEnd(ln)
            val segStart = maxOf(start, lineCharStart)
            val segEnd = minOf(end, lineCharEnd)
            if (segEnd <= segStart) continue
            val xA = layout.getPrimaryHorizontal(segStart)
            // getPrimaryHorizontal(offset) at a soft-wrap boundary returns the
            // NEXT line's left edge, collapsing the rect to full width. When the
            // segment reaches the visual end of this line, use getLineRight.
            val xB = if (segEnd >= layout.getLineVisibleEnd(ln)) {
                layout.getLineRight(ln)
            } else {
                layout.getPrimaryHorizontal(segEnd)
            }
            val top = layout.getLineTop(ln)
            val bot = layout.getLineBottom(ln)
            rects.add(
                Rect(
                    x = loc[0] + padL - sx + minOf(xA, xB).toDouble(),
                    y = loc[1] + padT - sy + top.toDouble(),
                    width = kotlin.math.abs(xB - xA).toDouble(),
                    height = (bot - top).toDouble(),
                )
            )
        }
        return rects
    }

    /**
     * Text-marker channel: when a node carries no real ClickableSpan / virtual
     * node but its text embeds link markers (a paired bracket run or a markdown
     * `[text](url)`), emit ONE region per marker, each with its own
     * Layout-derived rect. This is the fix for the self-drawn multi-link
     * agreement row, where the whole "<A><B><C>" run would otherwise collapse
     * into a single block.
     *
     * Bracket detection is script-agnostic: it scans for any of the paired
     * "title/quote" delimiters in [BRACKET_PAIRS] rather than a single locale's.
     * The set spans CJK guillemets (《…》「…」『…』【…】) and European angle
     * quotes («…»), so the same self-drawn-row support works regardless of the
     * app's language. Add a pair here to cover a new convention.
     */
    private fun markerRegions(tv: TextView): List<InteractionRegion> {
        val text = tv.text?.toString() ?: return emptyList()
        if (text.isEmpty()) return emptyList()
        val out = ArrayList<InteractionRegion>()

        // Paired bracket links, any script: <open>…<close>. Scan all pairs and
        // emit regions in text order so a mixed "《A》 «B»" row still resolves to
        // distinct targets.
        data class Marker(val start: Int, val end: Int)
        val markers = ArrayList<Marker>()
        for ((open, close) in BRACKET_PAIRS) {
            var i = 0
            while (true) {
                val o = text.indexOf(open, i)
                if (o < 0) break
                val c = text.indexOf(close, o + 1)
                if (c < 0) break
                markers.add(Marker(o, c + 1))
                i = c + 1
            }
        }
        markers.sortBy { it.start }
        for (m in markers) {
            out.add(
                InteractionRegion(
                    source = RegionSource.textMarker,
                    label = text.substring(m.start, m.end),
                    charStart = m.start,
                    charEnd = m.end,
                    rects = rectsForRange(tv, m.start, m.end),
                )
            )
        }

        // Markdown links: [text](url)
        for (m in MARKDOWN_LINK.findAll(text)) {
            val whole = m.range // covers [text](url)
            out.add(
                InteractionRegion(
                    source = RegionSource.textMarker,
                    label = m.groupValues[1],
                    target = m.groupValues[2],
                    charStart = whole.first,
                    charEnd = whole.last + 1,
                    rects = rectsForRange(tv, whole.first, whole.last + 1),
                )
            )
        }
        return out
    }

    /**
     * Paired "title/quote" delimiters used to mark an embedded link inside a
     * self-drawn text run, across scripts. Order doesn't matter; matches are
     * re-sorted by position. Keep open/close distinct (no symmetric quotes like
     * `"…"`, which can't be paired unambiguously by scanning).
     */
    private val BRACKET_PAIRS = listOf(
        '《' to '》', // CJK double angle (book title)
        '「' to '」', // CJK corner
        '『' to '』', // CJK white corner
        '【' to '】', // CJK lenticular
        '«' to '»',  // European guillemets (e.g. fr / ru / many EU locales)
    )

    private val MARKDOWN_LINK = Regex("""\[([^]]+)]\(([^)]+)\)""")

    // --- Channel 2: virtual accessibility sub-nodes -----------------------

    private fun virtualA11yRegions(view: View): List<InteractionRegion> {
        val provider = try {
            view.accessibilityNodeProvider
        } catch (_: Throwable) {
            null
        } ?: return emptyList()

        val out = ArrayList<InteractionRegion>()
        try {
            // The host view's virtual node is HOST_VIEW_ID (= -1); its children
            // are the exposed sub-regions.
            val hostId = android.view.accessibility.AccessibilityNodeProvider.HOST_VIEW_ID
            val root = provider.createAccessibilityNodeInfo(hostId) ?: return emptyList()
            val childCount = root.childCount
            val loc = IntArray(2)
            view.getLocationOnScreen(loc)
            for (i in 0 until childCount) {
                // Child virtual ids aren't directly enumerable across all impls;
                // probe a bounded range of plausible ids via the provider.
                // ExploreByTouchHelper assigns small sequential ids.
                val childInfo = provider.createAccessibilityNodeInfo(i) ?: continue
                val bounds = AndroidRect()
                childInfo.getBoundsInScreen(bounds)
                if (bounds.width() <= 0 || bounds.height() <= 0) continue
                out.add(
                    InteractionRegion(
                        source = RegionSource.a11yVirtual,
                        label = childInfo.text?.toString() ?: childInfo.contentDescription?.toString(),
                        rects = listOf(
                            Rect(
                                x = bounds.left.toDouble(),
                                y = bounds.top.toDouble(),
                                width = bounds.width().toDouble(),
                                height = bounds.height().toDouble(),
                            )
                        ),
                    )
                )
            }
        } catch (_: Throwable) {
            return out
        }
        return out
    }

    // --- Channel 3: touch delegate ----------------------------------------

    private fun touchDelegateRegion(view: View): InteractionRegion? {
        val delegate = try {
            view.touchDelegate
        } catch (_: Throwable) {
            null
        } ?: return null
        // TouchDelegate stores its bounds privately; read mBounds reflectively.
        return try {
            val field = android.view.TouchDelegate::class.java.getDeclaredField("mBounds")
            field.isAccessible = true
            val b = field.get(delegate) as? AndroidRect ?: return null
            val loc = IntArray(2)
            view.getLocationOnScreen(loc)
            // mBounds is in the delegate-host's local coords; offset to screen.
            InteractionRegion(
                source = RegionSource.touchDelegate,
                rects = listOf(
                    Rect(
                        x = (loc[0] + b.left).toDouble(),
                        y = (loc[1] + b.top).toDouble(),
                        width = b.width().toDouble(),
                        height = b.height().toDouble(),
                    )
                ),
            )
        } catch (_: Throwable) {
            null
        }
    }

    // --- Char grid --------------------------------------------------------

    private fun charGrid(tv: TextView): CharGrid? {
        val text = tv.text?.toString() ?: return null
        if (text.isEmpty()) return null
        val layout = tv.layout ?: return CharGrid(text = text, lines = emptyList(), approximate = true)

        val loc = IntArray(2)
        tv.getLocationOnScreen(loc)
        val padL = tv.totalPaddingLeft
        val padT = tv.totalPaddingTop
        val sx = tv.scrollX
        val sy = tv.scrollY

        val textLen = layout.text.length
        var approximate = false
        val lines = ArrayList<CharLine>(layout.lineCount)
        for (ln in 0 until layout.lineCount) {
            val ls = layout.getLineStart(ln)
            val le = layout.getLineEnd(ln)
            // BiDi/RTL: getPrimaryHorizontal is still per-offset correct, but a
            // logical [start,end) range can map to a non-contiguous visual span,
            // so flag the grid approximate for honesty on mixed-direction lines.
            if (layout.getParagraphDirection(ln) != Layout.DIR_LEFT_TO_RIGHT) approximate = true

            // Real per-character boundary X, straight from the laid-out glyphs.
            // For the trailing boundary at a soft wrap, getPrimaryHorizontal
            // would jump to the next line's left edge, so use getLineRight there.
            val xOffsets = ArrayList<Double>((le - ls) + 1)
            val baseX = (loc[0] + padL - sx).toDouble()
            for (off in ls..le) {
                val x: Double = when {
                    off >= textLen -> layout.getLineRight(ln).toDouble()
                    off == le && le > ls && off >= layout.getLineVisibleEnd(ln) -> layout.getLineRight(ln).toDouble()
                    else -> layout.getPrimaryHorizontal(off).toDouble()
                }
                xOffsets.add(baseX + x)
            }
            lines.add(
                CharLine(
                    line = ln,
                    start = ls,
                    end = le,
                    top = (loc[1] + padT - sy + layout.getLineTop(ln)).toDouble(),
                    bottom = (loc[1] + padT - sy + layout.getLineBottom(ln)).toDouble(),
                    xOffsets = xOffsets,
                )
            )
        }
        return CharGrid(text = text, lines = lines, approximate = approximate)
    }

    /**
     * Does this run carry a *structural* link marker — a paired bracket from
     * [BRACKET_PAIRS] or a markdown `](` — that [markerRegions] can split on?
     *
     * Detection is deliberately structural, not lexical: it does NOT match on
     * natural-language keywords (e.g. "agreement"/"terms"/"privacy" in any
     * language). Reticle is a general-purpose tool, so it must not assume an
     * app's language or domain.
     * Plain clickable phrases with no markup are still fully targetable by
     * substring through the always-emitted char grid; they simply aren't
     * *flagged* as suspected multi-region from their wording.
     */
    private fun looksLikeEmbeddedLink(text: String?): Boolean {
        if (text.isNullOrBlank()) return false
        if (text.contains("](")) return true // markdown link
        return BRACKET_PAIRS.any { (open, close) ->
            val o = text.indexOf(open)
            o >= 0 && text.indexOf(close, o + 1) >= 0
        }
    }
}
