package dev.reticle.core

/**
 * Did the page receive the touch, and on which element?
 *
 * This is the only fact about a tap that does not come from Reticle's own arithmetic.
 * Everything else a tap reports is what it INTENDED: the selector resolved, the rect
 * was re-read and had stopped moving, the coordinate was dispatched. If the DOM
 * coordinate fold is wrong, all of that is still true and the touch lands somewhere
 * else — measured on a real hybrid page whose rects were off by roughly 130px, where a
 * `--css` tap missed twice, reported `settled=1` both times, and only a screenshot
 * revealed it (#234).
 *
 * The cause of that particular offset was found and removed (the fold read the page
 * scroll one moment and the rects another; rects are viewport-space now). What was left
 * is the shape of the failure: silent. A fold can be wrong for reasons that have not
 * happened yet, and a native view drawn over a web view eats the touch with no trace at
 * all. So the page is asked directly.
 *
 * ## What the answer is made of
 *
 * `WebPointerWitnessScript` records the last pointer event's target in the page; the
 * traversal compares that target against each element it captures BY IDENTITY and marks
 * the one that matches (`domPointerHit`), publishing the coordinate and the age on the
 * web view host node. This class turns that pair into one of three statements:
 *
 *  - the touch landed on the element aimed at, or inside it — nothing to say, which is
 *    the case on every ordinary screen (a warning that fires everywhere is one nobody
 *    reads);
 *  - the touch landed on a DIFFERENT element — named, with the coordinate it arrived
 *    at, so the disagreement between the projected rect and the rendered position is
 *    visible and measurable instead of invisible;
 *  - no touch reached the page at all — which is what a coordinate swallowed by a
 *    native overlay looks like from in here.
 *
 * ## What it deliberately refuses to judge
 *
 * Silence, not a guess, whenever the evidence cannot carry a verdict: a target that is
 * not a DOM node, a page whose DOM could not be read in the capture being judged, a
 * target inside a frame the witness cannot be installed in (a sealed frame — events do
 * not cross that boundary either), and a record too old to belong to the gesture being
 * reported. That last one matters: the witness holds ONE record, so an ancient tap must
 * not be presented as this one's landing.
 *
 * Kept identical to `DomTapWitness` in ReticleProtocol (Swift), and the judgement is
 * pinned for both by `reticle-protocol/fixtures/dom-tap-witness.cases.json`.
 */
object DomTapWitness {

    /** The touch arrived in the page, on something else. */
    const val LANDED_ELSEWHERE = "dom-tap-landed-elsewhere"

    /** The page never saw a pointer event for this gesture. */
    const val NOT_RECEIVED = "dom-tap-not-received"

    /**
     * How old a witnessed pointer may be and still be attributed to the tap being
     * reported. The read happens a few hundred milliseconds after dispatch; anything
     * much older is a previous gesture's record and is treated as "no touch for this
     * one" rather than misattributed.
     */
    const val MAX_AGE_MS = 2500L

    /** How the element that received the touch relates to the one aimed at. */
    enum class Relation {
        /** Off-tree: a pointer arrived, no captured element matched it. */
        unknown,

        /** A sibling/cousin — the plain miss. */
        other,

        /** The touch landed on an element that CONTAINS the one aimed at. */
        ancestor,
    }

    /**
     * The structured judgement: what the fixture pins, and what [describe] renders.
     * `null` from [of] means there is nothing to say.
     */
    data class Verdict(
        val token: String,
        /** The ref that received the touch; null when it was off-tree or absent. */
        val landedOn: String? = null,
        /** Viewport coordinates the touch arrived at, "x,y"; null when none arrived. */
        val at: String? = null,
        val relation: Relation = Relation.unknown,
    )

    fun of(after: Snapshot, intendedRef: String): Verdict? {
        val intended = after.nodes[intendedRef] ?: return null
        if (intended.kind != NodeKind.domNode) return null
        val host = hostViewOf(after, intended) ?: return null
        // A capture that could not read this page cannot be asked where a touch went.
        if (host.custom["domStatus"] != null) return null
        // The witness lives per document and events do not cross a sealed frame, so a
        // target inside one is unwitnessed rather than untouched.
        if (insideOpaqueFrame(after, intended)) return null
        val age = (host.custom["domPointerAgeMs"] as? MetadataValue.Integer)?.value
        val x = (host.custom["domPointerX"] as? MetadataValue.Integer)?.value
        val y = (host.custom["domPointerY"] as? MetadataValue.Integer)?.value
        if (age == null || x == null || y == null || age > MAX_AGE_MS) {
            return Verdict(NOT_RECEIVED)
        }
        val hit = after.nodes.values.firstOrNull {
            (it.custom["domPointerHit"] as? MetadataValue.Bool)?.value == true
        }
        val at = "$x,$y"
        if (hit == null) return Verdict(LANDED_ELSEWHERE, at = at, relation = Relation.unknown)
        // The element aimed at, or anything inside it: a tap on a button lands on the
        // span that draws its caption, and that is the button being tapped.
        if (hit.ref == intended.ref || isDescendant(after, hit, intended.ref)) return null
        val relation = if (isDescendant(after, intended, hit.ref)) Relation.ancestor else Relation.other
        return Verdict(LANDED_ELSEWHERE, landedOn = hit.ref, at = at, relation = relation)
    }

    /** The one-line complaint for [of], or null when there is nothing to say. */
    fun describe(after: Snapshot, intendedRef: String): String? {
        val verdict = of(after, intendedRef) ?: return null
        val intended = after.nodes[intendedRef]
        val aimedAt = intended?.domCssSelector()?.let { "'$it'" } ?: intendedRef
        if (verdict.token == NOT_RECEIVED) {
            return "the page received no pointer event for this tap, so nothing in it was " +
                "touched — the coordinate went somewhere else entirely (a native view drawn " +
                "over the web view, or a projected rect that does not match what is rendered). " +
                "Compare `ui screenshot` with the rect for $aimedAt, and prefer a selector the " +
                "page itself vouches for"
        }
        val landed = verdict.landedOn?.let { ref ->
            val node = after.nodes[ref]
            val what = node?.domCssSelector() ?: ref
            when (verdict.relation) {
                Relation.ancestor ->
                    "on $ref ('$what'), which CONTAINS $aimedAt rather than being it"
                else -> "on $ref ('$what'), not on $aimedAt"
            }
        } ?: "on an element that is not in this capture, not on $aimedAt"
        return "the touch arrived in the page at (${verdict.at}) $landed, so this page's " +
            "DOM rects do not agree with what is rendered — the tap dispatched where the tree " +
            "said and the page was hit elsewhere. Re-capture (`ui report`) and compare the two " +
            "rects; on iOS `act activate --css` needs no coordinates at all"
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

    private fun isDescendant(snapshot: Snapshot, node: Node, ancestorRef: String): Boolean {
        var current = node.parentRef?.let { snapshot.nodes[it] }
        val seen = HashSet<String>()
        while (current != null && seen.add(current.ref)) {
            if (current.ref == ancestorRef) return true
            current = current.parentRef?.let { snapshot.nodes[it] }
        }
        return false
    }

    /**
     * Is any frame ABOVE this node one the top document could not walk itself?
     *
     * Such a frame's document is another origin's: the witness cannot be installed in
     * it, and its events do not cross the boundary either — so an absent record there
     * says nothing at all about where the touch went. `domFramePierced` marks the nodes
     * that were read by a per-frame evaluation, which is exactly that case.
     */
    private fun insideOpaqueFrame(snapshot: Snapshot, node: Node): Boolean {
        var current = node.parentRef?.let { snapshot.nodes[it] }
        val seen = HashSet<String>()
        while (current != null && seen.add(current.ref)) {
            val opaque = (current.custom["domFrameOpaque"] as? MetadataValue.Text)?.value
            val pierced = (current.custom["domFramePierced"] as? MetadataValue.Text)?.value
            if (!opaque.isNullOrBlank() || !pierced.isNullOrBlank()) return true
            current = current.parentRef?.let { snapshot.nodes[it] }
        }
        return false
    }
}
