package dev.reticle.core

/**
 * Is a DOM node's rect consistent with the web view that draws it?
 *
 * A DOM rect is computed in the PAGE's coordinates and folded into device
 * coordinates using the host view's frame, the page's scroll offsets and any
 * enclosing iframe offset. Every one of those is a chance to be wrong, and being
 * wrong here is silent in the worst way: `act tap` aims at the reported rect,
 * reports `settled=1`, and the touch lands somewhere else entirely. Measured while
 * driving a real hybrid flow — one page's rects were offset from what was on screen
 * by roughly 130px, a css tap missed twice, and tapping the visually-correct spot
 * worked. Only a screenshot revealed it.
 *
 * What this can and cannot see. A fold that is wrong by a small amount is
 * indistinguishable from a correct one from inside the tree — there is no second
 * source to compare against, so Reticle does not guess. A fold that puts a node's
 * CENTRE outside the view that draws it is different: that is impossible for a
 * correctly-folded rect, whatever the page did, so it can be stated as a fact.
 *
 * The check is deliberately the strong one only. A partially-visible element
 * legitimately hangs over its host's edge (an in-page scroll container mid-scroll,
 * a sticky header being clipped), so overlap alone proves nothing and would fire on
 * ordinary screens — a warning that fires on ordinary screens is one nobody reads.
 *
 * Kept identical to `DomRectCheck` in ReticleProtocol (Swift).
 */
object DomRectCheck {

    /** The wire/warning token for a rect folded outside its own web view. */
    const val OUTSIDE_HOST = "dom-rect-outside-host"

    /**
     * The complaint about [ref], or null when there is nothing to say.
     *
     * Null covers every case Reticle cannot judge: a native node, a DOM node with no
     * captured host (an orphan), a missing frame.
     */
    fun outsideHost(snapshot: Snapshot, ref: String): String? {
        val node = snapshot.nodes[ref] ?: return null
        if (node.kind != NodeKind.domNode) return null
        val frame = node.frame ?: return null
        val host = hostViewOf(snapshot, node) ?: return null
        val hostFrame = host.frame ?: return null
        if (hostFrame.width <= 0.0 || hostFrame.height <= 0.0) return null
        val cx = frame.centerX
        val cy = frame.centerY
        val inside = cx >= hostFrame.x && cx <= hostFrame.x + hostFrame.width &&
            cy >= hostFrame.y && cy <= hostFrame.y + hostFrame.height
        if (inside) return null
        return "$ref's DOM rect is folded to a point OUTSIDE the web view that draws it " +
            "(${host.testId ?: host.ref} at [${hostFrame.x.toInt()},${hostFrame.y.toInt()} " +
            "${hostFrame.width.toInt()}x${hostFrame.height.toInt()}]), so the page-to-device fold " +
            "for this node is wrong and a tap at its centre cannot land on it — re-capture " +
            "(`ui report`) and, if it persists, target the element by `act activate --css`, which " +
            "needs no coordinates"
    }

    /** The nearest non-DOM ancestor: the view hosting this document. */
    private fun hostViewOf(snapshot: Snapshot, node: Node): Node? {
        var current = node.parentRef?.let { snapshot.nodes[it] }
        val seen = HashSet<String>()
        while (current != null && seen.add(current.ref)) {
            if (current.kind != NodeKind.domNode) return current
            current = current.parentRef?.let { snapshot.nodes[it] }
        }
        return null
    }
}
