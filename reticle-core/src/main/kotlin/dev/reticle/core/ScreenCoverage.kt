package dev.reticle.core

import kotlin.math.ceil
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * How much of the screen an agent can actually address, and why a given
 * coordinate could not be.
 *
 * Reticle's contract is that a model with no visual capability can drive a
 * running app. Every `act tap --point` is a place that contract broke: the agent
 * measured pixels because nothing in the projection covered the thing it wanted.
 * That fallback used to be SILENT — the tap reported success and the gap left no
 * trace — so the only way to find one was to run a flow by hand and notice.
 *
 * Two questions are answered here, from the tree alone:
 *
 *  - [at] — for ONE point: is there an addressable node over it, and if not, what
 *    is in the way. Attached to every coordinate tap, so a coordinate is either
 *    justified by a named boundary or reported as an unnecessary fallback.
 *  - [of] — for the WHOLE screen: what share of the touch-relevant area has an
 *    addressable node over it. That number is the direct measure of the contract.
 *
 * Deliberately honest about one limit, stated in the rendering rather than hidden
 * in it: a cell where a node IS captured but nothing is interactive is NOT counted
 * as a gap. Without pixels, a paragraph of text and a control the projection
 * failed to mark are the same observation, and guessing would turn every screen
 * into a false report.
 *
 * Kept identical to `ScreenCoverage` in ReticleProtocol (Swift) and pinned for
 * both by reticle-protocol/fixtures/screen-coverage.cases.json.
 */
object ScreenCoverage {

    /** Default sampling cell for [of], in device pixels. */
    const val DEFAULT_CELL_PX = 32.0

    /** How many gap groups [CoverageReport.render] lists before summarizing. */
    const val MAX_LISTED_GAPS = 10

    // Reason tokens. Machine-readable half of a verdict; the sentence is the
    // other half. Spelled here once so the Swift twin and the fixture agree.
    const val REASON_ADDRESSABLE = "selector-available"
    const val REASON_CROSS_ORIGIN = "iframe:cross-origin"
    const val REASON_DOM_CAPPED = "dom:capped"
    const val REASON_DOM_UNAVAILABLE = "dom:unavailable"
    const val REASON_DOM_KERNEL = "dom:unsupported-kernel"
    const val REASON_WHEEL = "wheel"
    const val REASON_CONTAINER_ONLY = "container-only"

    /** How deep [deepestAt] descends. A DOM-heavy screen is deep; the walk is not. */
    private const val MAX_FIELD_DEPTH = 60
    const val REASON_NOT_INTERACTIVE = "no-interactive-node"
    const val REASON_NOTHING_CAPTURED = "nothing-captured"
    const val REASON_OFF_SCREEN = "off-screen"

    /**
     * Above this share of the screen, an interactive node is a CONTAINER rather
     * than a control, and its addressability does not carry the points inside it.
     *
     * Measured, and the reason the first cut of this file reported a hybrid screen
     * as 100% addressable: an Android `WebView` is itself focusable/clickable and
     * carries a resource id, so it satisfies every test a control does while
     * covering the whole display. A selector tap on it lands on ITS centre — not on
     * the thing the agent was aiming at — so counting it as cover for 2550 sampled
     * cells turned the one number that measures the blind-agent contract into a
     * constant. A control the agent can actually aim at is small; a screen-sized
     * tappable rectangle is scenery.
     */
    const val CONTAINER_AREA_FRACTION = 0.5

    /**
     * The check itself could not run — the tree was unreadable when the coordinate
     * was dispatched. Reported rather than omitted: a missing verdict would read
     * as "the coordinate was fine", which is the silence this whole file exists to
     * remove.
     */
    const val REASON_UNAVAILABLE = "coverage:unavailable"

    // Obstruction tokens: WHO gets the touch instead of the target. Distinct from
    // the coverage reasons above, which answer "could a selector have named this
    // point" — a point can be perfectly addressable and still unreachable.
    const val OBSTRUCTED_BY_KEYBOARD = "occluded:keyboard"
    const val OBSTRUCTED_BY_WINDOW = "occluded:window"
    const val OBSTRUCTED_BY_NODE = "occluded:node"

    /** A verdict that says the check failed, naming why. */
    fun unavailable(x: Double, y: Double, why: String): PointCoverage = PointCoverage(
        x = x,
        y = y,
        covered = false,
        reason = REASON_UNAVAILABLE,
        detail = why,
    )

    /**
     * Every visible node that has a frame, in the order a touch would meet them:
     * later entries are drawn on top. Window stacking first (the same order
     * [Snapshot.windowRefs] reports, bottom to top), then document order inside a
     * window — which IS draw order for a view tree.
     */
    private fun stack(snapshot: Snapshot): Stacked {
        val windowOrder = snapshot.windowRefs().withIndex().associate { (i, ref) -> ref to i }
        val documentOrder = snapshot.refsInDocumentOrder()
        val positions = documentOrder.withIndex().associate { (i, ref) -> ref to i }
        val layer = HashMap<String, Int>()
        val nodes = documentOrder
            .mapNotNull { snapshot.nodes[it] }
            .filter { it.isVisible && it.frame != null }
            .onEach { layer[it.ref] = snapshot.windowRefOf(it.ref)?.let { w -> windowOrder[w] } ?: -1 }
            .sortedWith(compareBy({ layer[it.ref] ?: -1 }, { positions[it.ref] ?: 0 }))
        return Stacked(nodes, layer, CssHandle.Index(snapshot))
    }

    /** Draw-ordered nodes plus which window layer each one is in. */
    private class Stacked(
        val nodes: List<Node>,
        val layer: Map<String, Int>,
        /**
         * Shortest-css-handle index for the same snapshot. Built here for the same
         * reason the stack is: a whole-screen sample asks thousands of times and the
         * snapshot does not change between samples.
         */
        val cssHandles: CssHandle.Index,
    )

    /** Is this node one an agent can aim a selector at right now? */
    private fun addressable(node: Node): Boolean =
        node.isInteractive && node.hasTargetingSignal()

    /**
     * The flag that would have hit [node], most stable handle first.
     *
     * `--ref` is last and is still a real answer: a ref is addressable within the
     * capture it came from, which is exactly the scope a tap has.
     */
    fun selectorFlagFor(node: Node, cssHandle: String? = null): String {
        node.testId?.let { return "--test-id $it" }
        node.resourceId?.let { return "--resource-id $it" }
        // The SHORTEST css that still names this node alone, when a snapshot was
        // available to decide that against: a full ancestor path is ~400 characters
        // of lineage in a hint whose whole job is to be read. See `CssHandle`.
        (cssHandle ?: node.domCssSelector())?.let { return "--css '$it'" }
        val label = node.contentDescription ?: node.text
        if (!label.isNullOrBlank()) return "--label \"${label.clipCodePoints(40)}\""
        return "--ref ${node.ref}"
    }

    /** The boundary this node declares, or null when it declares none. */
    private fun boundaryOf(node: Node): Pair<String, String>? {
        if (node.domCrossOriginFrame()) {
            return REASON_CROSS_ORIGIN to
                "the frame at ${node.ref} is cross-origin, so its document is unreadable by " +
                "browser policy — coordinates are the only path into it"
        }
        node.domCappedAt()?.let { captured ->
            return "$REASON_DOM_CAPPED($captured)" to
                "the DOM walk under ${node.ref} stopped at its node cap ($captured node(s) captured), " +
                "so nodes here were never captured at all — narrow the page or scroll"
        }
        if (node.domUnavailable()) {
            return REASON_DOM_UNAVAILABLE to
                "the DOM under ${node.ref} could not be read at capture time"
        }
        if (node.domKernelUnsupported()) {
            return REASON_DOM_KERNEL to
                "${node.ref} is a third-party WebView kernel" +
                (node.domKernelName()?.let { " ($it)" } ?: "") +
                " with no DOM bridge at all"
        }
        if (node.suspectedWheel) {
            return REASON_WHEEL to
                "${node.ref} is a wheel column whose candidate values exist only as pixels — " +
                "drive it with `act swipe`"
        }
        return null
    }

    /**
     * What covers one coordinate, and whether a selector could have reached it.
     *
     * Computed for every coordinate tap. When the answer is
     * [REASON_ADDRESSABLE] the coordinate was NOT needed and the report says
     * which flag would have worked — that is the case this exists to catch, since
     * a pixel-measured tap on an addressable node is a silent loss of the
     * re-resolution, settle and readback a selector tap carries.
     */
    fun at(snapshot: Snapshot, x: Double, y: Double): PointCoverage =
        verdict(snapshot, stack(snapshot), x, y)

    /**
     * Who receives the touch at (x, y) instead of [targetRef] — or null when the
     * target itself is on top there.
     *
     * A separate question from [at], and the one that was missing: [at] answers
     * "could a selector have named this point", which a covered point answers YES
     * to even when the touch cannot reach it. Measured on a physical device, both
     * halves silent:
     *
     *  - a third-party debug overlay's small floating window sat over a form
     *    control; `act tap --css …` resolved the control, dispatched, reported
     *    `settled=1`, and the overlay opened its own screen;
     *  - a button under the IME was tapped with the keyboard up and nothing
     *    happened, while `ui compact` for the same node already printed
     *    `occluded-by:keyboard` and even suggested `act hide-keyboard`.
     *
     * So the fact was computed and rendered in the READ path while the ACT path
     * ignored it. This is that fact, addressed at a point, for the act path to
     * carry.
     *
     * Three sources, in the order a touch meets them:
     *
     *  1. the IME — another process's window above every app window;
     *  2. a HIGHER window layer than the target's (dialog, popup, toast);
     *  3. a later sibling in the same window (draw order) that consumes the touch —
     *     interactive for a native view, anything not `pointer-events: none` for a
     *     DOM element, whose default is to eat the click.
     *
     * A screen-sized interactive container is deliberately NOT an obstruction: it
     * is the same scenery [CONTAINER_AREA_FRACTION] exists for. An app that wraps
     * its content in one full-screen clickable frame (debug overlays do exactly
     * this) would otherwise mark every tap on the screen as obstructed, and a
     * warning that fires on every tap is one nobody reads. A NATIVE modal scrim gets
     * caught by rule 2 instead, because it lives in its own window; an in-page one
     * has no window of its own, so it is caught by rule 3 as a painted out-of-flow
     * DOM layer.
     */
    fun obstruction(
        snapshot: Snapshot,
        x: Double,
        y: Double,
        targetRef: String? = null,
    ): TapObstruction? {
        val keyboard = snapshot.screen.keyboard?.takeIf { it.visible }?.frame
        if (keyboard?.contains(x, y) == true) {
            return TapObstruction(
                reason = OBSTRUCTED_BY_KEYBOARD,
                detail = "the IME covers this point, so the touch goes to the keyboard and not to " +
                    "the app — dismiss it with `act hide-keyboard` first",
                ref = null,
            )
        }
        val target = targetRef?.let { snapshot.nodes[it] } ?: return null
        val stacked = stack(snapshot)
        val targetLayer = stacked.layer[target.ref] ?: -1
        val here = stacked.nodes.filter { it.frame?.contains(x, y) == true }
        val topLayer = here.maxOfOrNull { stacked.layer[it.ref] ?: -1 } ?: -1
        if (topLayer > targetLayer) {
            // Name the WINDOW rather than whichever of its children happens to be
            // topmost: the window is the thing a caller dismisses.
            val front = here.lastOrNull { (stacked.layer[it.ref] ?: -1) == topLayer }
            val window = front?.ref?.let { snapshot.windowRefOf(it) } ?: front?.ref
            return TapObstruction(
                reason = OBSTRUCTED_BY_WINDOW,
                detail = "a window above ${target.ref} covers this point" +
                    (window?.let { " ($it)" } ?: "") +
                    " — the touch lands in that window, not on the target",
                ref = window,
            )
        }
        val screenArea = snapshot.screen.size.width * snapshot.screen.size.height
        laterSiblingCovering(snapshot, target, x, y, screenArea * CONTAINER_AREA_FRACTION)?.let { above ->
            val why = if (above.kind == NodeKind.domNode) {
                "and the page did not opt it out of hit-testing"
            } else {
                "and is itself interactive"
            }
            return TapObstruction(
                reason = OBSTRUCTED_BY_NODE,
                detail = "${above.ref} (${above.role ?: above.typeName}) is drawn over ${target.ref} " +
                    "at this point $why, so it consumes the touch",
                ref = above.ref,
            )
        }
        return null
    }

    /**
     * The nearest interactive node drawn AFTER [node] that contains the point.
     *
     * Walks up the ancestors and looks at each level's later siblings, which is
     * draw order for a view tree. Non-interactive views are skipped: a decorative
     * transparent frame lets the touch fall through, so reporting one would be a
     * false alarm. Twin of the rule `CompactObservation` renders as
     * `occluded-by:` — sharing the conclusion, not the code, because that one asks
     * about a node's CENTRE while a tap asks about the point it is about to
     * dispatch.
     */
    private fun laterSiblingCovering(
        snapshot: Snapshot,
        node: Node,
        x: Double,
        y: Double,
        containerArea: Double,
    ): Node? {
        var current = node
        var parent = current.parentRef?.let { snapshot.nodes[it] }
        val seen = HashSet<String>()
        while (parent != null && seen.add(parent.ref)) {
            val siblings = parent.children
            val position = siblings.indexOf(current.ref)
            if (position >= 0) {
                for (i in siblings.size - 1 downTo position + 1) {
                    val above = snapshot.nodes[siblings[i]] ?: continue
                    if (!above.isVisible) continue
                    val isDom = above.kind == NodeKind.domNode
                    // A native cover has to be interactive to eat the touch; a DOM
                    // element eats it by default unless the page said
                    // `pointer-events: none`. See CompactObservation.consumesTouch.
                    if (if (isDom) above.domPointerEventsNone() else !above.isInteractive) continue
                    val frame = above.frame ?: continue
                    if (!frame.contains(x, y)) continue
                    if (frame.width * frame.height > containerArea) {
                        // Scenery is exempt (see the doc above) — but a full-screen DOM
                        // layer that is out of flow AND paints its own box is a dialog
                        // backdrop, which is the one full-screen cover that really does
                        // consume every touch on the screen.
                        if (!(isDom && above.domOutOfFlow() && above.domPaintsBackground())) continue
                    }
                    return above
                }
            }
            current = parent
            parent = current.parentRef?.let { snapshot.nodes[it] }
        }
        return null
    }

    /**
     * [at] against a pre-built stack.
     *
     * Sampling a whole screen asks this thousands of times, and the stack costs a
     * document-order walk plus a parent walk per node — building it per sample made
     * `of` quadratic in the tree for no gain, since the tree does not change between
     * samples of one snapshot.
     */
    private fun verdict(snapshot: Snapshot, stacked: Stacked, x: Double, y: Double): PointCoverage {
        val size = snapshot.screen.size
        if (x < 0.0 || y < 0.0 || x > size.width || y > size.height) {
            return PointCoverage(
                x = x,
                y = y,
                covered = false,
                reason = REASON_OFF_SCREEN,
                detail = "this point is outside the ${size.width.toInt()}x${size.height.toInt()} screen",
                ref = null,
                selector = null,
            )
        }
        val here = stacked.nodes.filter { it.frame?.contains(x, y) == true }
        // Only the TOP window layer at this point can answer for it. A stacked screen
        // keeps the window behind it alive and fully laid out, and its nodes are
        // usually smaller than the front screen's containers — so a rule that picks
        // the smallest node would reach through the front screen and name a control
        // the touch can never reach. Measured on the sample app: a coordinate inside a
        // cross-origin frame on the top window was answered with `--test-id
        // scenario.list` from the home screen underneath it.
        val topLayer = here.maxOfOrNull { stacked.layer[it.ref] ?: -1 } ?: -1
        val containing = here.filter { (stacked.layer[it.ref] ?: -1) == topLayer }
        // Topmost first: the boundary nearest the touch is the one in the way.
        val topDown = containing.asReversed()
        val screenArea = size.width * size.height
        val containerArea = screenArea * CONTAINER_AREA_FRACTION
        fun areaOf(node: Node): Double = node.frame?.let { it.width * it.height } ?: 0.0
        val addressableHere = topDown.filter { addressable(it) }
        // The SMALLEST addressable node wins, not the topmost: nesting means several
        // contain the point, and the innermost is the control while its ancestors are
        // layout. Ties keep topmost-first order, which is draw order.
        val hit = addressableHere
            .filter { areaOf(it) <= containerArea }
            // A boundary HOST never counts as cover for the points inside it, even
            // when it is tappable and carries an id — measured on the real
            // third-party widget this file came from: `iframe:cross-origin` sat on a
            // frame element that was itself `tappable` with a test id, so every point
            // in the widget read "a selector covers this" while the four steps the
            // agent needed were inside a document nothing can read. Tapping the frame
            // hits its centre; the boundary answer is the true one, and it still
            // names the ref for a caller who did mean the frame.
            .filter { boundaryOf(it) == null }
            .minByOrNull { areaOf(it) }
        if (hit != null) {
            val flag = selectorFlagFor(hit, stacked.cssHandles.of(hit))
            val frame = hit.frame
            val taps = frame?.let { " and would tap (${it.centerX.toInt()},${it.centerY.toInt()})" } ?: ""
            return PointCoverage(
                x = x,
                y = y,
                covered = true,
                reason = REASON_ADDRESSABLE,
                detail = "$flag resolves to ${hit.ref} (${hit.role ?: hit.typeName}), whose frame " +
                    "contains this point$taps",
                ref = hit.ref,
                selector = flag,
            )
        }
        for (node in topDown) {
            val boundary = boundaryOf(node) ?: continue
            return PointCoverage(
                x = x,
                y = y,
                covered = false,
                reason = boundary.first,
                detail = boundary.second,
                ref = node.ref,
                selector = null,
            )
        }
        // Nothing small is addressable here and no boundary explains it, but a
        // screen-sized tappable container does contain the point. That container is
        // not cover: a selector tap on it lands on its own centre, so the thing at
        // THIS point has no handle. Naming it (with its tap point) is what separates
        // "you could have used a selector" from "a coordinate was the only path".
        addressableHere.minByOrNull { areaOf(it) }?.let { container ->
            val frame = container.frame
            val taps = frame?.let { "(${it.centerX.toInt()},${it.centerY.toInt()})" } ?: "(unknown)"
            return PointCoverage(
                x = x,
                y = y,
                covered = false,
                reason = REASON_CONTAINER_ONLY,
                detail = "the only addressable node here is ${container.ref} " +
                    "(${container.role ?: container.typeName}), a screen-sized container whose own " +
                    "tap point is $taps — nothing smaller is captured at this point" +
                    namedFieldNote(snapshot, x, y),
                ref = container.ref,
                selector = null,
            )
        }
        val top = topDown.firstOrNull()
            ?: return PointCoverage(
                x = x,
                y = y,
                covered = false,
                reason = REASON_NOTHING_CAPTURED,
                detail = "no captured node contains this point",
                ref = null,
                selector = null,
            )
        return PointCoverage(
            x = x,
            y = y,
            covered = false,
            reason = REASON_NOT_INTERACTIVE,
            detail = "the topmost node here is ${top.ref} (${top.role ?: top.typeName}) and it is not " +
                "interactive, so no selector aims at this point" + namedFieldNote(snapshot, x, y),
            ref = top.ref,
            selector = null,
        )
    }

    /**
     * The whole screen, sampled on a grid of [cellPx] cells.
     *
     * A grid rather than exact rect arithmetic because overlapping frames make an
     * exact union area a different (and much larger) problem, and because the
     * sampling is then a stated fact in the output rather than a hidden
     * approximation.
     */
    /**
     * The name of the field this inert point belongs to, when the page named it and
     * exposed no control for it.
     *
     * The case measured on a real form: five dropdowns whose trigger is a bare
     * `<div>` with no role, no `aria-*`, no text and nothing the page declares as
     * clickable. Their `<label>` IS captured, so the screen reads as fully
     * addressable while those five fields can only be driven by coordinates — the
     * one number meant to measure the blind-agent contract says 100% exactly where
     * the contract is broken.
     *
     * Narrow, because a wrong name here would be worse than the silence it
     * replaces: the enclosing field wrapper (at most three levels up) must hold
     * EXACTLY ONE label-ish node and NO interactive node at all. A named field with
     * a control beside it is not this case, and a group legend over several
     * controls is not either.
     */
    /**
     * The deepest visible node under this point, starting from [ref].
     *
     * The per-cell verdict names the node that ANSWERS for the point — a
     * screen-sized web view, usually — and that is the right answer for coverage
     * but the wrong starting point for "which field is this". Measured: five named
     * dropdowns all sat in `container-only` cells whose ref was the web view, so
     * looking at the verdict's own node found nothing about them.
     */
    /**
     * The `— inside the named field "…"` clause, when this point falls in one.
     *
     * The whole-screen report already lists these (`named but inert:`), and without
     * this the two halves of the same tool contradicted each other on the same
     * screen: `ui coverage` named `"Employment type" r404 [57,786 964x195]` while a tap
     * at a point inside that rect answered `nothing smaller is captured at this
     * point`. The per-point warning is where a caller reads it — at the moment it
     * dispatches the coordinate — so it is the half that needed it most.
     */
    private fun namedFieldNote(snapshot: Snapshot, x: Double, y: Double): String {
        val deepest = deepestAt(snapshot, snapshot.rootRef, x, y) ?: return ""
        val (name, host) = labelledFieldName(snapshot, deepest.ref) ?: return ""
        return " — it is inside the named field \"$name\" ($host), which the page exposes no " +
            "control for, so a coordinate is the only path to it"
    }

    private fun deepestAt(snapshot: Snapshot, ref: String, cx: Double, cy: Double): Node? {
        val start = snapshot.nodes[ref] ?: return null
        var best: Node? = start.takeIf { it.frame?.contains(cx, cy) == true }
        val seen = HashSet<String>()
        fun visit(node: Node, depth: Int) {
            if (!seen.add(node.ref) || depth > MAX_FIELD_DEPTH) return
            if (node.isVisible && node.frame?.contains(cx, cy) == true) best = node
            node.children.forEach { child -> snapshot.nodes[child]?.let { visit(it, depth + 1) } }
        }
        visit(start, 0)
        return best
    }

    private fun labelledFieldName(snapshot: Snapshot, ref: String?): Pair<String, String>? {
        var current = ref?.let { snapshot.nodes[it] } ?: return null
        var match: Pair<String, String>? = null
        var level = 0
        while (level < 3) {
            val parent = current.parentRef?.let { snapshot.nodes[it] } ?: return null
            val descendants = ArrayList<Node>()
            val seen = HashSet<String>()
            fun collect(node: Node) {
                if (!seen.add(node.ref)) return
                descendants.add(node)
                node.children.forEach { child -> snapshot.nodes[child]?.let(::collect) }
            }
            parent.children.forEach { child -> snapshot.nodes[child]?.let(::collect) }
            // An interactive node at this level ends the walk — but it does not undo a
            // match found INSIDE it: the field wrapper below may still be a named
            // field with no control, while a sibling field further out has one.
            if (descendants.any { it.isInteractive }) return match
            val labels = descendants.filter {
                it.role == "label" && !it.text.isNullOrBlank()
            }
            if (labels.size == 1) match = labels[0].text!! to parent.ref
            current = parent
            level++
        }
        // The OUTERMOST wrapper that still satisfies the rule, not the first one
        // found: walking up from a different starting node stops at a different
        // level, and reporting each of those separately listed one field up to three
        // times with three different hosts for the same rect.
        return match
    }

    fun of(snapshot: Snapshot, cellPx: Double = DEFAULT_CELL_PX): CoverageReport {
        val size = snapshot.screen.size
        val cell = if (cellPx > 0.0) cellPx else DEFAULT_CELL_PX
        val columns = maxOf(0, ceil(size.width / cell).toInt())
        val rows = maxOf(0, ceil(size.height / cell).toInt())
        val stacked = stack(snapshot)
        val keyboardFrame = snapshot.screen.keyboard?.takeIf { it.visible }?.frame
        var addressableCells = 0
        var containerOnlyCells = 0
        var inertCells = 0
        var emptyCells = 0
        var keyboardCells = 0
        // Keyed by reason + host ref so two frames with the same boundary stay two
        // rows: the rect is what an agent acts on.
        val gaps = LinkedHashMap<String, CoverageGap>()
        val labelled = LinkedHashMap<String, LabelledInertRegion>()
        for (row in 0 until rows) {
            for (column in 0 until columns) {
                val cx = column * cell + cell / 2.0
                val cy = row * cell + cell / 2.0
                if (keyboardFrame?.contains(cx, cy) == true) {
                    keyboardCells++
                    continue
                }
                val verdict = verdict(snapshot, stacked, cx, cy)
                when {
                    verdict.covered -> addressableCells++
                    verdict.reason == REASON_NOTHING_CAPTURED || verdict.reason == REASON_OFF_SCREEN ->
                        emptyCells++
                    verdict.reason == REASON_NOT_INTERACTIVE -> {
                        inertCells++
                        labelledFieldName(snapshot, deepestAt(snapshot, verdict.ref ?: snapshot.rootRef, cx, cy)?.ref)
                            ?.let { (name, host) ->
                            // Keyed by name + rect — see the twin above.
                            val hostFrame = snapshot.nodes[host]?.frame
                            val key = "$name|${hostFrame?.x?.toInt()},${hostFrame?.y?.toInt()}," +
                                "${hostFrame?.width?.toInt()}x${hostFrame?.height?.toInt()}"
                            val existing = labelled[key]
                            labelled[key] = existing?.copy(cells = existing.cells + 1)
                                ?: LabelledInertRegion(
                                    name = name,
                                    ref = host,
                                    frame = snapshot.nodes[host]?.frame,
                                    cells = 1,
                                )
                        }
                    }
                    // A screen-sized interactive container over the point is not
                    // cover — that rule stands, and the per-point verdict still
                    // says so — but it is not a GAP either, and counting it as one
                    // made a whole class of app unreadable. Measured on a login
                    // screen carrying a full-screen debug overlay (an interactive
                    // `FrameLayout` the size of the display): 1004 of 1462
                    // touch-relevant cells came back unreachable and the screen read
                    // as 31% addressable, while every control on it resolved and
                    // every tap landed. Reported on its own line instead, so the
                    // fact survives without poisoning the one number that measures
                    // the blind-agent contract. A boundary the container declares —
                    // a capped DOM walk, an unreadable one, a cross-origin frame —
                    // is answered before this branch and still counts as a gap.
                    verdict.reason == REASON_CONTAINER_ONLY -> {
                        containerOnlyCells++
                        // A named field inside a screen-sized container is the same
                        // observation as one in an inert region: the page named it and
                        // exposed no control, so only a coordinate reaches it.
                        labelledFieldName(snapshot, deepestAt(snapshot, verdict.ref ?: snapshot.rootRef, cx, cy)?.ref)
                            ?.let { (name, host) ->
                                // Keyed by name + RECT, not by ref: the same field
                                // has several nested wrappers with the identical rect,
                                // and walking up from different cells stops at
                                // different ones, which listed one field several times.
                                val hostFrame = snapshot.nodes[host]?.frame
                                val key = "$name|${hostFrame?.x?.toInt()},${hostFrame?.y?.toInt()}," +
                                    "${hostFrame?.width?.toInt()}x${hostFrame?.height?.toInt()}"
                                val existing = labelled[key]
                                labelled[key] = existing?.copy(cells = existing.cells + 1)
                                    ?: LabelledInertRegion(
                                        name = name,
                                        ref = host,
                                        frame = snapshot.nodes[host]?.frame,
                                        cells = 1,
                                    )
                            }
                    }
                    else -> {
                        val ref = verdict.ref ?: "?"
                        val key = "${verdict.reason}|$ref"
                        val existing = gaps[key]
                        if (existing == null) {
                            gaps[key] = CoverageGap(
                                reason = verdict.reason,
                                ref = ref,
                                frame = snapshot.nodes[ref]?.frame,
                                cells = 1,
                            )
                        } else {
                            gaps[key] = existing.copy(cells = existing.cells + 1)
                        }
                    }
                }
            }
        }
        return CoverageReport(
            screen = size,
            cellPx = cell,
            columns = columns,
            rows = rows,
            addressableCells = addressableCells,
            inertCells = inertCells,
            emptyCells = emptyCells,
            keyboardCells = keyboardCells,
            containerOnlyCells = containerOnlyCells,
            labelledInert = labelled.values.sortedWith(
                compareByDescending<LabelledInertRegion> { it.cells }.thenBy { it.name }
            ),
            gaps = gaps.values.sortedWith(compareByDescending<CoverageGap> { it.cells }
                .thenBy { it.reason }
                .thenBy { it.ref }),
        )
    }
}

/** The verdict for one coordinate. */
@Serializable
data class PointCoverage(
    val x: Double,
    val y: Double,
    /** True when an addressable node's frame contains this point. */
    val covered: Boolean,
    /** Machine token: `selector-available`, `iframe:cross-origin`, `dom:capped(N)`, … */
    val reason: String,
    /** The same fact as a sentence, naming the node in the way. */
    val detail: String,
    /** The node the verdict is about: the hit, the boundary host, or the topmost node. */
    val ref: String? = null,
    /** The flag that would have resolved this point, when one would have. */
    val selector: String? = null,
) {
    /**
     * The one line a coordinate tap prints, as a warning either way.
     *
     * Both outcomes are warnings on purpose. An uncovered point is a coverage gap
     * to file; a COVERED one is worse in a quieter way — the agent measured pixels
     * for something it could have named, throwing away the re-resolution, settle
     * confirm and stale-rect evidence a selector tap carries.
     */
    fun warning(): String {
        val where = "(${x.toInt()},${y.toInt()})"
        if (reason == ScreenCoverage.REASON_UNAVAILABLE) {
            return "could not check whether a selector covers $where — $detail"
        }
        if (covered) {
            return "--point was not needed at $where: $detail. " +
                "A selector tap re-resolves and confirms its target; a coordinate does neither"
        }
        return "no semantic selector covers $where — $reason: $detail"
    }

    /**
     * The wire shape a coordinate tap's result carries, twin of the Swift
     * `PointCoverage.jsonObject`. Assembled here rather than in each host so the
     * two cannot name the same fact differently.
     */
    fun wire(): JsonObject = buildJsonObject {
        put("x", x)
        put("y", y)
        put("covered", covered)
        put("reason", reason)
        put("detail", detail)
        put("warning", warning())
        ref?.let { put("ref", it) }
        selector?.let { put("selector", it) }
    }
}

/**
 * Who gets the touch instead of the target, as a tap result field.
 *
 * Carried by EVERY tap, selector or coordinate — unlike [PointCoverage], which
 * only a coordinate tap needs. A selector tap is exactly the case that used to be
 * silent here: it re-resolves, confirms the rect has stopped moving, reports
 * `settled=1`, and then hands the touch to whatever is drawn on top.
 */
@Serializable
data class TapObstruction(
    /** `occluded:keyboard`, `occluded:window` or `occluded:node`. */
    val reason: String,
    /** The same fact as a sentence, naming what is in the way and what to do. */
    val detail: String,
    /** The occluding window or node, when one is nameable (the IME is not a node). */
    val ref: String? = null,
) {
    /**
     * The line a tap prints when something is in the way.
     *
     * A warning rather than a refusal: the touch may still be the right thing to
     * dispatch (a scrim that closes on outside taps, an overlay the caller means
     * to hit), and a hard failure on a heuristic would strand a flow. What the
     * caller must not have is silence — `settled=1` with nothing else reads as
     * "the app got it".
     */
    fun warning(x: Double, y: Double): String =
        "the touch at (${x.toInt()},${y.toInt()}) may not reach the target — $reason: $detail"

    /** Wire shape, twin of the Swift `TapObstruction.jsonObject`. */
    fun wire(x: Double, y: Double): JsonObject = buildJsonObject {
        put("reason", reason)
        put("detail", detail)
        put("warning", warning(x, y))
        ref?.let { put("ref", it) }
    }
}

/** One boundary-marked region and how much of the sampled grid it takes. */
@Serializable
data class CoverageGap(
    val reason: String,
    val ref: String,
    val frame: Rect? = null,
    val cells: Int,
)

/**
 * A field the page NAMED but exposed no control for: its `<label>` is captured and
 * nothing in the field is interactive, so the region reads as ordinary inert
 * content while it can in fact only be driven by coordinates.
 */
@Serializable
data class LabelledInertRegion(
    val name: String,
    val ref: String,
    val frame: Rect? = null,
    val cells: Int,
)

/** The whole-screen answer to "how much of this screen is unreachable?". */
@Serializable
data class CoverageReport(
    val screen: Size,
    val cellPx: Double,
    val columns: Int,
    val rows: Int,
    val addressableCells: Int,
    /** A node is captured here, but nothing over the point is interactive. */
    val inertCells: Int,
    /** No captured node contains the point at all. */
    val emptyCells: Int,
    /** Covered by the system keyboard — another process's window, never a node. */
    val keyboardCells: Int,
    /**
     * Only a screen-sized interactive container answers here.
     *
     * Counted apart from [gaps] for the reason [inertCells] is: the container is not
     * cover (a selector tap on it lands on its own centre), but a transparent
     * full-screen frame over ordinary content is not a region the app failed to
     * expose either. Folding these into the gap total made a screen whose every
     * control worked read as 31% addressable.
     */
    val containerOnlyCells: Int = 0,
    /**
     * Named fields with no addressable control — see [LabelledInertRegion]. Listed,
     * not counted as gaps: nothing here proves the region is tappable, and inferring
     * that from a label would be the guess this file refuses everywhere else. Naming
     * them is what stops `addressable: 100%` from reading as "every control on this
     * screen has a selector".
     */
    val labelledInert: List<LabelledInertRegion> = emptyList(),
    val gaps: List<CoverageGap>,
) {
    /** Cells inside a region a named boundary makes unreachable. */
    val unreachableCells: Int get() = gaps.sumOf { it.cells }

    /**
     * Cells the contract is measured over: those with an addressable node, plus
     * those a boundary makes unreachable. Inert and empty cells are excluded —
     * see the note in [render].
     */
    val touchRelevantCells: Int get() = addressableCells + unreachableCells

    /**
     * Integer percent of [touchRelevantCells] that is addressable, truncated.
     * Truncating (rather than rounding) keeps the two ports byte-identical
     * without either of them depending on a platform rounding rule.
     */
    val addressablePercent: Int
        get() = if (touchRelevantCells == 0) 100 else addressableCells * 100 / touchRelevantCells

    fun render(): String = buildString {
        append("coverage: ${screen.width.toInt()}x${screen.height.toInt()}, ")
            .append("sampled on a ${columns}x$rows grid of ${cellPx.toInt()}px cells\n")
        if (touchRelevantCells == 0) {
            append("addressable: no touch-relevant cells on this screen — nothing interactive and no ")
                .append("named boundary was captured\n")
        } else {
            append("addressable: $addressableCells of $touchRelevantCells touch-relevant cell(s) ")
                .append("($addressablePercent%)\n")
        }
        if (gaps.isEmpty()) {
            append("unreachable: none — every touch-relevant cell has an addressable node over it\n")
        } else {
            append("unreachable: $unreachableCells cell(s)\n")
            for (gap in gaps.take(ScreenCoverage.MAX_LISTED_GAPS)) {
                val where = gap.frame?.let {
                    " [${it.x.toInt()},${it.y.toInt()} ${it.width.toInt()}x${it.height.toInt()}]"
                } ?: ""
                append("  ${gap.reason} ${gap.ref}$where ${gap.cells} cell(s)\n")
            }
            val more = gaps.size - ScreenCoverage.MAX_LISTED_GAPS
            if (more > 0) append("  ($more more gap group(s))\n")
        }
        if (containerOnlyCells > 0) {
            append("container-only: $containerOnlyCells cell(s) — only a screen-sized container ")
                .append("answers here (a selector tap on it lands on its own centre)\n")
        }
        append("inert: $inertCells cell(s) — a node is captured there, none of it interactive\n")
        if (labelledInert.isNotEmpty()) {
            append("named but inert: ${labelledInert.size} field(s) — the page names these and exposes ")
                .append("no control for them, so only a coordinate reaches them\n")
            for (region in labelledInert.take(ScreenCoverage.MAX_LISTED_GAPS)) {
                val where = region.frame?.let {
                    " [${it.x.toInt()},${it.y.toInt()} ${it.width.toInt()}x${it.height.toInt()}]"
                } ?: ""
                append("  \"${region.name}\" ${region.ref}$where ${region.cells} cell(s)\n")
            }
            val more = labelledInert.size - ScreenCoverage.MAX_LISTED_GAPS
            if (more > 0) append("  ($more more named field(s))\n")
        }
        append("empty: $emptyCells cell(s) — no captured node contains the point\n")
        if (keyboardCells > 0) {
            append("keyboard: $keyboardCells cell(s) covered by the IME (another process's window)\n")
        }
        append("(inert, empty and container-only cells are NOT counted as gaps: without pixels, plain ")
            .append("content and a ")
            .append("control the projection failed to mark are the same observation)")
    }
}
