package dev.reticle.core

/**
 * Where a tap on a node can actually land: the part of its frame that is still
 * on screen and not cut away by a clipping ancestor.
 *
 * A node's frame is its LAYOUT box, and a tap aimed at the centre of that box is
 * only correct while the whole box is visible. Two ways it stops being, both
 * measured while driving a real hybrid flow, both silent:
 *
 *  - **Off screen.** A row inside a bottom sheet had frame `y=2403 h=128` on a
 *    2412px-tall display, so the computed tap point was **y=2468 — below the
 *    bottom of the screen**. `act tap` dispatched it and reported `settled=1`.
 *    `act scroll-to` on the same node then brought it into view and the identical
 *    tap worked, so the fix was knowable at dispatch time.
 *  - **Clipped by an ancestor.** After that sheet scrolled, rows that had gone
 *    UNDER its sticky header still carried their full, unclipped rects. A tap
 *    aimed at such a row's centre went to the dimmed page behind the sheet; the
 *    sheet stayed open, and the result said `settled=1`.
 *
 * So the reachable rect is the frame intersected with every clipping ancestor and
 * with the screen. Empty means the tap has nowhere to go and the caller needs
 * `act scroll-to`, not a coordinate. Non-empty but different from the frame means
 * the tap should aim at the visible part rather than at a centre that is no longer
 * inside it.
 *
 * What clips, and why only these:
 *
 *  - a native scroll container ([Node.scroll] is present) — a `ScrollView` /
 *    `RecyclerView` draws its children inside its own bounds;
 *  - a DOM element with a non-`visible` `overflow` — the CSS rule for a scroll
 *    port, read from the style the WebView bridge already captures;
 *  - the window the node belongs to, and the screen itself.
 *
 * An ordinary layout container is NOT treated as clipping: Android views can and
 * do draw outside their parent's bounds (`clipChildren=false`), so assuming
 * otherwise would move taps that were landing correctly.
 *
 * Kept identical to `TapReach` in ReticleProtocol (Swift) and pinned for both by
 * reticle-protocol/fixtures/tap-reach.cases.json.
 */
object TapReach {

    /** Why a tap cannot reach a target at all. */
    const val UNREACHABLE_OFF_SCREEN = "off-screen"
    const val UNREACHABLE_CLIPPED = "clipped"

    /**
     * The tap point for [ref], plus what had to be taken into account.
     *
     * [point] is null when the node is unreachable — [reason] then says which of
     * the two it is and [by] names the ancestor that clips it, when one does.
     */
    data class Reach(
        val point: Point?,
        /** The reachable rect, or null when there is none. */
        val rect: Rect?,
        /** True when [point] is NOT the frame's own centre. */
        val adjusted: Boolean,
        /** `off-screen` / `clipped`, or null when the target is reachable. */
        val reason: String? = null,
        /** The clipping ancestor, when the frame was cut by one. */
        val by: String? = null,
    ) {
        /**
         * The sentence a caller gets. Actionable on purpose: every one of these
         * ends in the command that fixes it, because "this tap cannot land" with
         * no next step is only marginally better than the silence it replaces.
         */
        fun explain(ref: String): String = when (reason) {
            UNREACHABLE_OFF_SCREEN ->
                "$ref is laid out off screen, so a tap at its centre lands outside the display — " +
                    "bring it into view first with `act scroll-to`"
            UNREACHABLE_CLIPPED ->
                "$ref is fully clipped by ${by ?: "an ancestor"}, so no part of it can receive a " +
                    "touch — scroll it into its container's viewport with `act scroll-to`"
            else ->
                "$ref is only partly visible" + (by?.let { " (clipped by $it)" } ?: "") +
                    ", so the tap aims at the visible part rather than at the frame's centre"
        }
    }

    /**
     * Does this node clip what is drawn inside it?
     *
     * Deliberately narrow — see the class note. A false positive here MOVES a tap
     * that was landing correctly, which is worse than the miss it prevents.
     */
    private fun clips(node: Node, screen: Rect): Boolean {
        if (node.scroll != null) return true
        // A window clips its children — but a FULL-SCREEN window and the screen are
        // the same cut, and naming the window for it sends the caller looking for a
        // container that is not the problem. Only a smaller window (a dialog) is
        // worth reporting as the clipper.
        if (node.kind == NodeKind.window) {
            val frame = node.frame ?: return false
            return frame.width < screen.width || frame.height < screen.height
        }
        val overflowX = (node.custom["domStyleOverflowX"] as? MetadataValue.Text)?.value
        val overflowY = (node.custom["domStyleOverflowY"] as? MetadataValue.Text)?.value
        return (overflowX != null && overflowX != "visible") ||
            (overflowY != null && overflowY != "visible")
    }

    /**
     * How much of a cut is no cut at all, in device pixels.
     *
     * Two reasons a containing ancestor used to come back as a clipper. DOM rects
     * arrive as fractional device pixels, and rebuilding a rect from
     * `x + width - x` is not exact in binary floating point — so an intersection
     * that changed nothing compared UNEQUAL to the frame it came from. Measured on
     * a hybrid consent screen: a button at `x=473.6170277913412
     * w=361.8677083333333`, wholly inside the WebView that contains it, was
     * reported `only partly visible (clipped by that WebView)` while the tap went to
     * its exact centre — a contradiction that read as the reason the flow failed
     * and sent the caller looking for a clipping container that did not exist.
     * Sub-pixel layout rounding in a real page does the same thing for real.
     *
     * Half a pixel cannot move a tap, so a cut smaller than this is not reported
     * and does not move the aim.
     */
    private const val CLIP_EPSILON = 0.5

    /** Does [outer] contain [inner], up to [CLIP_EPSILON] on each edge? */
    private fun contains(outer: Rect, inner: Rect): Boolean =
        outer.x <= inner.x + CLIP_EPSILON &&
            outer.y <= inner.y + CLIP_EPSILON &&
            outer.x + outer.width >= inner.x + inner.width - CLIP_EPSILON &&
            outer.y + outer.height >= inner.y + inner.height - CLIP_EPSILON

    private fun intersect(a: Rect, b: Rect): Rect? {
        // Identity, not arithmetic, when nothing is actually cut — see CLIP_EPSILON.
        if (contains(b, a)) return a
        val left = maxOf(a.x, b.x)
        val top = maxOf(a.y, b.y)
        val right = minOf(a.x + a.width, b.x + b.width)
        val bottom = minOf(a.y + a.height, b.y + b.height)
        if (right <= left || bottom <= top) return null
        return Rect(left, top, right - left, bottom - top)
    }

    /**
     * Where a tap on [ref] can land in [snapshot].
     *
     * Returns a reachable point (the frame's centre when nothing interferes, the
     * visible part's centre when something does) or a reason it has none.
     */
    fun of(snapshot: Snapshot, ref: String): Reach? {
        val node = snapshot.nodes[ref] ?: return null
        val frame = node.frame ?: return null
        val screen = Rect(0.0, 0.0, snapshot.screen.size.width, snapshot.screen.size.height)
        // Screen first, and on the RAW frame: a node laid out past the bottom of the
        // display is off screen, full stop, and saying "clipped by the window" for
        // it would send the caller looking for a container that is not the problem.
        // Only once it is on screen at all do the ancestors get to cut it down.
        if (intersect(frame, screen) == null) {
            return Reach(null, null, adjusted = true, reason = UNREACHABLE_OFF_SCREEN)
        }
        var rect: Rect? = frame
        var clipper: String? = null
        var current = node.parentRef?.let { snapshot.nodes[it] }
        val seen = HashSet<String>()
        while (current != null && seen.add(current.ref)) {
            val bounds = current.frame
            if (bounds != null && clips(current, screen)) {
                val next = rect?.let { intersect(it, bounds) }
                if (next != rect) clipper = current.ref
                rect = next
                if (rect == null) break
            }
            current = current.parentRef?.let { snapshot.nodes[it] }
        }
        if (rect == null) {
            return Reach(null, null, adjusted = true, reason = UNREACHABLE_CLIPPED, by = clipper)
        }
        val onScreen = intersect(rect, screen)
            ?: return Reach(null, null, adjusted = true, reason = UNREACHABLE_OFF_SCREEN, by = clipper)
        val point = Point(onScreen.centerX, onScreen.centerY)
        val adjusted = onScreen != frame
        return Reach(point, onScreen, adjusted = adjusted, by = if (adjusted) clipper else null)
    }
}
