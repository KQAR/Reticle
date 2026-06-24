package dev.reticle.cli

import dev.reticle.core.AccessibilityTree
import dev.reticle.core.Node
import dev.reticle.core.Point
import dev.reticle.core.Rect
import dev.reticle.core.Selector
import dev.reticle.core.Snapshot

/**
 * Resolves a selector to a screen point for input dispatch. Encodes the
 * architecture rule:
 *
 *   "Use the accessibility tree first for movement and input; selector actions
 *    should only fall back to view frames when no accessibility match exists."
 *
 * So we try the accessibility tree first (testId / resourceId), then the full
 * snapshot's view frames, then a raw point.
 */
class SelectorResolver(
    private val snapshot: Snapshot,
    private val accessibility: AccessibilityTree,
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

        // 2. Accessibility tree first.
        selector.testId?.let { id ->
            accessibility.findByTestId(id)?.frame?.let { return Resolved(center(it), "accessibility:testId", refByTestId(id)) }
        }
        selector.resourceId?.let { id ->
            accessibility.findByResourceId(id)?.frame?.let { return Resolved(center(it), "accessibility:resourceId", refByResourceId(id)) }
        }
        selector.ref?.let { ref ->
            accessibility.node(ref)?.frame?.let { return Resolved(center(it), "accessibility:ref", ref) }
        }

        // 3. Fall back to view-tree frames.
        val node = when {
            selector.testId != null -> snapshot.nodes.values.firstOrNull { it.testId == selector.testId }
            selector.resourceId != null -> snapshot.nodes.values.firstOrNull { it.resourceId == selector.resourceId }
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
            ?.tapPoint()
            ?.let { return Resolved(it, "region:${node.regions.first { r -> r.label?.contains(needle, true) == true }.source}", node.ref) }

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
        else -> null
    }

    private fun center(rect: Rect) = Point(rect.centerX, rect.centerY)

    private fun refByTestId(id: String): String? =
        snapshot.nodes.values.firstOrNull { it.testId == id }?.ref

    private fun refByResourceId(id: String): String? =
        snapshot.nodes.values.firstOrNull { it.resourceId == id }?.ref
}
