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
        return Stacked(nodes, layer)
    }

    /** Draw-ordered nodes plus which window layer each one is in. */
    private class Stacked(val nodes: List<Node>, val layer: Map<String, Int>)

    /** Is this node one an agent can aim a selector at right now? */
    private fun addressable(node: Node): Boolean =
        node.isInteractive && node.hasTargetingSignal()

    /**
     * The flag that would have hit [node], most stable handle first.
     *
     * `--ref` is last and is still a real answer: a ref is addressable within the
     * capture it came from, which is exactly the scope a tap has.
     */
    fun selectorFlagFor(node: Node): String {
        node.testId?.let { return "--test-id $it" }
        node.resourceId?.let { return "--resource-id $it" }
        node.domCssSelector()?.let { return "--css '$it'" }
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
            val flag = selectorFlagFor(hit)
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
                    "tap point is $taps — nothing smaller is captured at this point",
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
                "interactive, so no selector aims at this point",
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
    fun of(snapshot: Snapshot, cellPx: Double = DEFAULT_CELL_PX): CoverageReport {
        val size = snapshot.screen.size
        val cell = if (cellPx > 0.0) cellPx else DEFAULT_CELL_PX
        val columns = maxOf(0, ceil(size.width / cell).toInt())
        val rows = maxOf(0, ceil(size.height / cell).toInt())
        val stacked = stack(snapshot)
        val keyboardFrame = snapshot.screen.keyboard?.takeIf { it.visible }?.frame
        var addressableCells = 0
        var inertCells = 0
        var emptyCells = 0
        var keyboardCells = 0
        // Keyed by reason + host ref so two frames with the same boundary stay two
        // rows: the rect is what an agent acts on.
        val gaps = LinkedHashMap<String, CoverageGap>()
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
                    verdict.reason == REASON_NOT_INTERACTIVE -> inertCells++
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

/** One boundary-marked region and how much of the sampled grid it takes. */
@Serializable
data class CoverageGap(
    val reason: String,
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
        append("inert: $inertCells cell(s) — a node is captured there, none of it interactive\n")
        append("empty: $emptyCells cell(s) — no captured node contains the point\n")
        if (keyboardCells > 0) {
            append("keyboard: $keyboardCells cell(s) covered by the IME (another process's window)\n")
        }
        append("(inert and empty cells are NOT counted as gaps: without pixels, plain content and a ")
            .append("control the projection failed to mark are the same observation)")
    }
}
