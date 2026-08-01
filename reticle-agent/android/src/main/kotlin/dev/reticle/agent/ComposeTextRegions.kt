package dev.reticle.agent

import dev.reticle.core.CharGrid
import dev.reticle.core.CharLine
import dev.reticle.core.InteractionRegion
import dev.reticle.core.Rect
import dev.reticle.core.RegionSource

/**
 * Sub-regions inside a Compose text node.
 *
 * `RegionProbe` decomposes a multi-region `TextView` through `Spanned` +
 * `Layout`; neither exists in Compose, so a `Text` with two `LinkAnnotation`s was
 * captured as ONE node with no regions and no char grid — a link inside Compose
 * text was simply not addressable, while the identical `ClickableSpan` row on a
 * View was. This closes that asymmetry using the same surface Compose exposes to
 * accessibility, and nothing private:
 *
 *  - `SemanticsProperties.Text` gives the `AnnotatedString`s, whose
 *    `getLinkAnnotations(start, end)` are the authored link ranges;
 *  - the `SemanticsActions.GetTextLayoutResult` action — the one TalkBack invokes
 *    — hands back a `TextLayoutResult`, i.e. the laid-out glyph geometry, the
 *    Compose analogue of `Layout`.
 *
 * All reflective, so the agent keeps its `compileOnly` Compose dependency, and
 * every step fails closed to "no regions" rather than guessing a rect.
 */
object ComposeTextRegions {

    /** Regions + char grid for one semantics node, in screen coordinates. */
    data class Result(
        val regions: List<InteractionRegion>,
        val charGrid: CharGrid?,
    )

    val EMPTY = Result(emptyList(), null)

    /**
     * [nodeFrame] is the node's already-converted screen frame; Compose text
     * geometry is relative to the text layout's own origin, which is that frame's
     * origin. [layout] is the node's `TextLayoutResult`, fetched once by the
     * caller — obtaining it runs the `GetTextLayoutResult` accessibility action,
     * so the caller shares one result between this probe and [ComposeTextStyle].
     */
    fun probe(semanticsNode: Any, nodeFrame: Rect?, layout: Any?): Result {
        if (nodeFrame == null || layout == null) return EMPTY
        val annotated = SemanticsReflect.annotatedText(semanticsNode) ?: return EMPTY
        val text = annotatedString(annotated) ?: return EMPTY
        if (text.isEmpty()) return EMPTY

        val regions = linkRanges(annotated).mapNotNull { (start, end, target) ->
            val rects = rectsForRange(layout, start, end, nodeFrame)
            if (rects.isEmpty()) null
            else InteractionRegion(
                source = RegionSource.span,
                label = text.substring(start.coerceIn(0, text.length), end.coerceIn(0, text.length)),
                target = target,
                charStart = start,
                charEnd = end,
                rects = rects,
            )
        }
        return Result(regions, charGrid(layout, text, nodeFrame))
    }

    // --- link ranges ------------------------------------------------------

    /**
     * `AnnotatedString.getLinkAnnotations(0, length)` → the authored link ranges.
     * The item is a `LinkAnnotation.Url` (carrying a url) or `.Clickable`
     * (carrying a tag); both identify the link, so either becomes the region's
     * target.
     */
    private fun linkRanges(annotated: Any): List<Triple<Int, Int, String?>> {
        return try {
            val length = ReticleReflect.invokeNoArg(annotated, "length") as? Int ?: return emptyList()
            val method = method(annotated, "getLinkAnnotations", 2) ?: return emptyList()
            val ranges = method.invoke(annotated, 0, length) as? List<*> ?: return emptyList()
            ranges.mapNotNull { range ->
                range ?: return@mapNotNull null
                val start = ReticleReflect.invokeNoArg(range, "getStart") as? Int ?: return@mapNotNull null
                val end = ReticleReflect.invokeNoArg(range, "getEnd") as? Int ?: return@mapNotNull null
                if (end <= start) return@mapNotNull null
                val item = ReticleReflect.invokeNoArg(range, "getItem")
                val target = item?.let {
                    ReticleReflect.invokeNoArg(it, "getUrl") as? String
                        ?: ReticleReflect.invokeNoArg(it, "getTag") as? String
                }
                Triple(start, end, target)
            }
        } catch (_: Throwable) {
            emptyList()
        }
    }

    private fun annotatedString(annotated: Any): String? =
        try {
            annotated.toString().takeIf { it.isNotEmpty() }
        } catch (_: Throwable) {
            null
        }

    // --- geometry ---------------------------------------------------------

    /**
     * Per-line screen rects for `[start, end)`, mirroring `RegionProbe`'s
     * `rectsForRange`: one rect per visual line, never a collapsed full-width
     * block, and the trailing edge taken from the line's right edge when the
     * range reaches a soft wrap.
     */
    private fun rectsForRange(layout: Any, start: Int, end: Int, frame: Rect): List<Rect> {
        return try {
            val firstLine = lineForOffset(layout, start) ?: return emptyList()
            val lastLine = lineForOffset(layout, (end - 1).coerceAtLeast(start)) ?: return emptyList()
            val out = ArrayList<Rect>(lastLine - firstLine + 1)
            for (line in firstLine..lastLine) {
                val lineStart = intAt(layout, "getLineStart", line) ?: continue
                val lineEnd = intAt(layout, "getLineEnd", line, visibleEnd = true) ?: continue
                val segStart = maxOf(start, lineStart)
                val segEnd = minOf(end, lineEnd)
                if (segEnd <= segStart) continue
                val xA = horizontal(layout, segStart) ?: continue
                val xB = if (segEnd >= lineEnd) {
                    floatAt(layout, "getLineRight", line) ?: horizontal(layout, segEnd) ?: continue
                } else {
                    horizontal(layout, segEnd) ?: continue
                }
                val top = floatAt(layout, "getLineTop", line) ?: continue
                val bottom = floatAt(layout, "getLineBottom", line) ?: continue
                out.add(
                    Rect(
                        x = frame.x + minOf(xA, xB),
                        y = frame.y + top,
                        width = kotlin.math.abs(xB - xA).toDouble(),
                        height = (bottom - top),
                    )
                )
            }
            out
        } catch (_: Throwable) {
            emptyList()
        }
    }

    /**
     * A char grid so an agent can target an arbitrary substring by coordinate —
     * the same last-resort channel View text already has.
     */
    private fun charGrid(layout: Any, text: String, frame: Rect): CharGrid? {
        return try {
            val lineCount = ReticleReflect.invokeNoArg(layout, "getLineCount") as? Int ?: return null
            val lines = ArrayList<CharLine>(lineCount)
            var approximate = false
            for (line in 0 until lineCount) {
                val start = intAt(layout, "getLineStart", line) ?: continue
                val end = intAt(layout, "getLineEnd", line, visibleEnd = true) ?: continue
                // Same honesty rule as the View char grid: on a mixed-direction
                // line a logical range can map to a non-contiguous visual span, so
                // flag the grid rather than returning a confidently wrong rect.
                if (!isLeftToRight(layout, start)) approximate = true
                val top = floatAt(layout, "getLineTop", line) ?: continue
                val bottom = floatAt(layout, "getLineBottom", line) ?: continue
                val xOffsets = ArrayList<Double>((end - start) + 1)
                for (offset in start..end) {
                    val x = if (offset >= end) {
                        floatAt(layout, "getLineRight", line) ?: horizontal(layout, offset)
                    } else {
                        horizontal(layout, offset)
                    } ?: continue
                    xOffsets.add(frame.x + x)
                }
                lines.add(
                    CharLine(
                        line = line,
                        start = start,
                        end = end,
                        top = frame.y + top,
                        bottom = frame.y + bottom,
                        xOffsets = xOffsets,
                    )
                )
            }
            if (lines.isEmpty()) null else CharGrid(text = text, lines = lines, approximate = approximate)
        } catch (_: Throwable) {
            null
        }
    }

    private fun lineForOffset(layout: Any, offset: Int): Int? = intAt(layout, "getLineForOffset", offset)

    /**
     * The char-grid loop calls these once per character offset, and
     * `getMethods()` clones the class's whole Method array per call — on the
     * main thread, per snapshot. Resolve once per (class, name, arity) through
     * [ReticleReflect.cachedMethod], as [SemanticsReflect] does for its getters.
     */
    private fun method(target: Any, name: String, paramCount: Int) =
        ReticleReflect.cachedMethod(target, "$name/$paramCount") { cls ->
            cls.methods.firstOrNull { it.name == name && it.parameterTypes.size == paramCount }
        }

    /** `TextLayoutResult.getParagraphDirection(offset)` == `ResolvedTextDirection.Ltr`. */
    private fun isLeftToRight(layout: Any, offset: Int): Boolean {
        return try {
            val m = method(layout, "getParagraphDirection", 1) ?: return true
            (m.invoke(layout, offset)?.toString() ?: "Ltr").contains("Ltr", ignoreCase = true)
        } catch (_: Throwable) {
            true
        }
    }

    /** `TextLayoutResult.getHorizontalPosition(offset, usePrimaryDirection)`. */
    private fun horizontal(layout: Any, offset: Int): Double? {
        return try {
            val m = method(layout, "getHorizontalPosition", 2) ?: return null
            (m.invoke(layout, offset, true) as? Float)?.toDouble()
        } catch (_: Throwable) {
            null
        }
    }

    private fun intAt(layout: Any, name: String, arg: Int, visibleEnd: Boolean? = null): Int? {
        return try {
            if (visibleEnd != null) {
                // getLineEnd(lineIndex, visibleEnd) — the two-arg form excludes the
                // trailing whitespace a soft wrap leaves on the line.
                val m = method(layout, name, 2)
                if (m != null) return m.invoke(layout, arg, visibleEnd) as? Int
            }
            val m = method(layout, name, 1) ?: return null
            m.invoke(layout, arg) as? Int
        } catch (_: Throwable) {
            null
        }
    }

    private fun floatAt(layout: Any, name: String, arg: Int): Double? {
        return try {
            val m = method(layout, name, 1) ?: return null
            (m.invoke(layout, arg) as? Float)?.toDouble()
        } catch (_: Throwable) {
            null
        }
    }
}
