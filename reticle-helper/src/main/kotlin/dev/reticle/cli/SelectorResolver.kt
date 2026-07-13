package dev.reticle.cli

import dev.reticle.core.MetadataValue
import dev.reticle.core.Node
import dev.reticle.core.Point
import dev.reticle.core.Rect
import dev.reticle.core.Selector
import dev.reticle.core.SemanticTree
import dev.reticle.core.Snapshot

/**
 * Resolves a selector to a screen point for input dispatch. Encodes the
 * architecture rule:
 *
 *   "Use the semantic tree first for movement and input; selector actions
 *    should only fall back to view frames when no semantic match exists."
 *
 * So we try the semantic tree first (testId / resourceId), then the full
 * snapshot's view frames, then a raw point.
 */
class SelectorResolver(
    private val snapshot: Snapshot,
    private val semantic: SemanticTree,
) {

    data class Resolved(val point: Point, val source: String, val ref: String?)

    fun resolve(selector: Selector): Resolved? {
        // 0. Region-within-node: target a sub-region (span / virtual / char
        //    range) inside a node, the multi-region case neither tree collapses.
        if (selector.region != null) {
            resolveRegion(selector)?.let { return it }
            // fall through to whole-node if the region couldn't be located
        }

        // 1. Raw point wins if explicitly provided.
        selector.point?.let { return Resolved(it, "point", null) }

        // 2. Semantic tree first. Use the matched node's own ref rather than
        //    re-scanning for it — the semantic tree preserves snapshot refs.
        selector.testId?.let { id ->
            semantic.findByTestId(id)?.let { n -> n.frame?.let { return Resolved(center(it), "semantic:testId", n.ref) } }
        }
        selector.resourceId?.let { id ->
            semantic.findByResourceId(id)?.let { n -> n.frame?.let { return Resolved(center(it), "semantic:resourceId", n.ref) } }
        }
        selector.cssSelector?.let { css ->
            nodeByCssSelector(css)?.let { n -> n.frame?.let { return Resolved(center(it), "dom:css", n.ref) } }
        }
        selector.ref?.let { ref ->
            semantic.node(ref)?.frame?.let { return Resolved(center(it), "semantic:ref", ref) }
        }

        // 3. Fall back to view-tree frames.
        val node = when {
            selector.testId != null -> snapshot.nodes.values.firstOrNull { it.testId == selector.testId }
            selector.resourceId != null -> snapshot.nodes.values.firstOrNull { it.resourceId == selector.resourceId }
            selector.cssSelector != null -> selector.cssSelector?.let(::nodeByCssSelector)
            selector.ref != null -> snapshot.nodes[selector.ref]
            else -> null
        }
        node?.frame?.let { return Resolved(center(it), "view", node.ref) }
        return null
    }

    /**
     * Resolve a sub-region inside the node identified by the selector. Order:
     *   1. a discovered region (span / virtual a11y) whose label contains the
     *      requested substring — most reliable, real hit-rect.
     *   2. the char grid: locate the substring's character range and compute
     *      its rect — works even when no region was discoverable (self-drawn).
     */
    private fun resolveRegion(selector: Selector): Resolved? {
        val node = nodeFor(selector) ?: return null
        val needle = selector.region ?: return null

        // 1. Discovered region by label match.
        node.regions
            .firstOrNull { it.label?.contains(needle, ignoreCase = true) == true }
            ?.let { region ->
                region.tapPoint()?.let { return Resolved(it, "region:${region.source}", node.ref) }
            }

        // 2. Char grid substring.
        node.charGrid?.let { grid ->
            val idx = grid.text.indexOf(needle)
            if (idx >= 0) {
                val rects = grid.rangeRects(idx, idx + needle.length)
                rects.firstOrNull()?.let {
                    val approxNote = if (grid.approximate) ":approx" else ""
                    return Resolved(Point(it.centerX, it.centerY), "charGrid$approxNote", node.ref)
                }
            }
        }
        return null
    }

    private fun nodeFor(selector: Selector): Node? = when {
        selector.ref != null -> snapshot.nodes[selector.ref]
        selector.testId != null -> snapshot.nodes.values.firstOrNull { it.testId == selector.testId }
        selector.resourceId != null -> snapshot.nodes.values.firstOrNull { it.resourceId == selector.resourceId }
        selector.cssSelector != null -> selector.cssSelector?.let(::nodeByCssSelector)
        else -> null
    }

    private fun center(rect: Rect) = Point(rect.centerX, rect.centerY)

    private fun nodeByCssSelector(cssSelector: String): Node? =
        snapshot.nodes.values.firstOrNull { node ->
            (node.custom["domCssSelector"] as? MetadataValue.Text)?.value == cssSelector
        }
}
