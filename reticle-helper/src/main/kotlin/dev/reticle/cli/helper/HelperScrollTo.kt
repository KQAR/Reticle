package dev.reticle.cli

import dev.reticle.cli.platform.DeviceController
import dev.reticle.cli.platform.InputDispatcher
import dev.reticle.core.Node
import dev.reticle.core.Rect
import dev.reticle.core.Selector
import dev.reticle.core.SelectorResolver
import dev.reticle.core.SemanticTree
import dev.reticle.core.Snapshot
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * `act scroll-to`: swipe a scrollable container until a selector resolves to a
 * point inside that container, then stop.
 *
 * Why this is a gesture and not a `wait`-style predicate. A recycling/lazy
 * container binds only its visible window, so a far-down row has NO node — the
 * flow "tap the 40th row" is unreachable with `tap` alone, and an agent scripting
 * blind swipes has no termination condition. The reason the earlier `wait --for
 * appears` proposal was dropped does not apply here: its success test was
 * `isVisible`, a weak per-platform proxy, whereas this one is *`act tap`'s own
 * resolution* plus containment in the scrolling container's rect. If scroll-to
 * reports found, the very next `tap` resolves the same way.
 *
 * What it never does: claim the element exists, or keep going past what the
 * container says it can do. Every outcome is reported as evidence — how many
 * swipes, which direction, which container, and (on failure) whether the
 * container hit its end or the swipe budget ran out. Those two failures mean
 * different things to an agent: the first says "this list does not contain it".
 */
internal object HelperScrollTo {

    /** Default swipe budget; a 60-row list needs ~4 at 60% of a viewport. */
    private const val DEFAULT_MAX_SWIPES = 12

    /**
     * A deliberately SLOW drag rather than a flick. A fast swipe flings, and a
     * flinging list keeps moving after the gesture returns — which made the
     * reported point stale before the next `tap` could use it (measured: scroll-to
     * reported row 40 at y=1486, the tap that followed resolved y=1420 and landed
     * on nothing). A slow drag barely flings at all.
     */
    private const val SWIPE_DURATION_MS = 700

    /** Between drags: let the frame bind before re-capturing. */
    private const val SETTLE_MS = 350L

    /** Settle budget once the target is found, and the poll interval inside it. */
    private const val STABILIZE_BUDGET_MS = 2_000L
    private const val STABILIZE_POLL_MS = 200L

    fun run(
        input: InputDispatcher,
        device: DeviceController,
        pkg: String,
        params: JsonObject,
    ): JsonObject {
        val selector = selectorFrom(params)
        if (selector.testId == null && selector.resourceId == null &&
            selector.cssSelector == null && selector.ref == null
        ) {
            throw CliError("scroll-to needs a selector (--test-id / --resource-id / --css / --ref)")
        }
        val maxSwipes = params.intOrNull("maxSwipes") ?: DEFAULT_MAX_SWIPES
        val requested = params.str("direction")?.lowercase()
        val client = runtimeClientFor(device, pkg, params)
        assertHealthy(client, pkg)

        var swipes = 0
        var lastDirection: String? = null
        // Locked after the first pick. Re-choosing per iteration made an absent
        // selector ping-pong: once the list hit the bottom, "the first available
        // direction" became `up`, and it scrolled back over ground it had already
        // covered until the budget ran out. One direction per run means reaching
        // the end is a complete sweep of that axis — which is what makes
        // "nothing under that selector came into view" a fact worth reporting.
        var lockedDirection: String? = null
        var container: Node? = null
        while (true) {
            val snapshot = client.snapshot()
            container = containerFor(snapshot, params)
            resolvedInside(snapshot, selector, container)?.let { firstHit ->
                // Report a point the NEXT command can still use: wait until the
                // target's resolved position stops moving. Without this the
                // contract is hollow — "found" would mean "was there a moment ago".
                val settled = stabilize(client, selector, container, firstHit)
                return buildJsonObject {
                    put("gesture", "scroll-to")
                    put("found", true)
                    put("swipes", swipes)
                    lastDirection?.let { put("direction", it) }
                    container?.let { put("container", it.testId ?: it.resourceId ?: it.ref) }
                    put("x", settled.target.point.x.toInt())
                    put("y", settled.target.point.y.toInt())
                    put("source", settled.target.source)
                    settled.target.ref?.let { put("ref", it) }
                    // Honest flag: false means the content was still moving when the
                    // budget ran out, so the point may already be stale.
                    put("settled", settled.stable)
                }
            }
            val scrollable = container ?: throw CliError(
                "scroll-to found no scrollable container on screen, so '${selector.describe()}' " +
                    "cannot be scrolled into view. " + SelectorDiagnostics.pointMiss(snapshot, selector)
            )
            val frame = scrollable.frame ?: throw CliError(
                "scroll-to: the scrollable container ${scrollable.ref} has no frame to swipe inside"
            )
            val direction = requested ?: lockedDirection ?: firstAvailableDirection(scrollable)
                ?: throw CliError(describeExhausted(scrollable, selector, swipes, lastDirection))
            lockedDirection = direction
            if (!canScroll(scrollable, direction)) {
                throw CliError(describeExhausted(scrollable, selector, swipes, direction))
            }
            if (swipes >= maxSwipes) {
                throw CliError(
                    "scroll-to gave up after $maxSwipes swipe(s) $direction inside " +
                        "'${scrollable.testId ?: scrollable.ref}' without resolving " +
                        "'${selector.describe()}'. The container can still scroll $direction — " +
                        "raise --max-swipes if the target is further away."
                )
            }
            swipe(input, frame, direction)
            lastDirection = direction
            swipes++
            Thread.sleep(SETTLE_MS)
        }
    }

    private data class Settled(val target: ResolvedTarget, val stable: Boolean)

    /**
     * Poll until the target resolves to the same point twice in a row — the list
     * has stopped moving — or the budget runs out. Returns the freshest target
     * either way, flagged with whether it actually settled.
     */
    private fun stabilize(
        client: RuntimeClient,
        selector: Selector,
        container: Node?,
        first: ResolvedTarget,
    ): Settled {
        val deadline = System.currentTimeMillis() + STABILIZE_BUDGET_MS
        var previous = first
        while (System.currentTimeMillis() < deadline) {
            Thread.sleep(STABILIZE_POLL_MS)
            val snapshot = client.snapshot()
            val current = resolvedInside(snapshot, selector, containerLike(snapshot, container))
                ?: return Settled(previous, false)
            if (samePoint(current.point, previous.point)) return Settled(current, true)
            previous = current
        }
        return Settled(previous, false)
    }

    /** The same container in a fresh snapshot; refs are minted per capture. */
    private fun containerLike(snapshot: Snapshot, container: Node?): Node? {
        val wanted = container ?: return null
        wanted.testId?.let { id -> snapshot.nodes.values.firstOrNull { it.testId == id }?.let { return it } }
        wanted.resourceId?.let { id -> snapshot.nodes.values.firstOrNull { it.resourceId == id }?.let { return it } }
        return containerFor(snapshot, buildJsonObject { })
    }

    private fun samePoint(a: dev.reticle.core.Point, b: dev.reticle.core.Point): Boolean =
        kotlin.math.abs(a.x - b.x) < 1.0 && kotlin.math.abs(a.y - b.y) < 1.0

    /**
     * The selector's tap target, but only when it lands inside the scrolling
     * container — a row bound at the very edge, half under a pinned header, is
     * not something a tap should be aimed at yet. With no container in play the
     * plain resolution stands.
     */
    private fun resolvedInside(
        snapshot: Snapshot,
        selector: Selector,
        container: Node?,
    ): ResolvedTarget? {
        val semantic = SemanticTree.build(snapshot)
        val resolved = SelectorResolver(snapshot, semantic).resolve(selector) ?: return null
        val frame = container?.frame ?: return ResolvedTarget(resolved.point, resolved.source, resolved.ref)
        val inside = resolved.point.x >= frame.x && resolved.point.x <= frame.x + frame.width &&
            resolved.point.y >= frame.y && resolved.point.y <= frame.y + frame.height
        return if (inside) ResolvedTarget(resolved.point, resolved.source, resolved.ref) else null
    }

    internal data class ResolvedTarget(
        val point: dev.reticle.core.Point,
        val source: String,
        val ref: String?,
    )

    /**
     * The container to scroll: an explicit `--container` selector, else the
     * largest scrollable node **in the topmost window**.
     *
     * The window filter is not a nicety. A snapshot holds every window in the
     * process, including the Activity left behind — and the background screen's
     * page scroller can easily be larger than the foreground list, so plain
     * "largest scrollable" picked a container the user cannot even see (measured:
     * it reported the home screen's scroller while the list scenario was on
     * screen). Within the top window, largest is the right tie-break: a nested
     * scroller is usually the smaller of the two, and moving the page instead
     * would scroll the wrong thing.
     */
    private fun containerFor(snapshot: Snapshot, params: JsonObject): Node? {
        params.str("container")?.let { wanted ->
            return snapshot.nodes.values.firstOrNull {
                (it.testId == wanted || it.resourceId == wanted || it.ref == wanted)
            } ?: throw CliError("scroll-to: no node matched --container '$wanted'")
        }
        val scrollables = snapshot.nodes.values
            .filter { it.scroll?.isScrollable == true && it.frame != null }
        // Highest-stacked window that HAS a scroller, not simply the top window:
        // the system keyboard is itself a window in the scene on iOS, so a strict
        // "top window only" rule would find nothing whenever it is up.
        val windowRefs = snapshot.root()?.children
            ?.filter { snapshot.nodes[it]?.kind == dev.reticle.core.NodeKind.window }
            .orEmpty()
        val scoped = windowRefs.asReversed()
            .asSequence()
            .map { ref -> scrollables.filter { windowRefOf(snapshot, it) == ref } }
            .firstOrNull { it.isNotEmpty() }
            ?: scrollables
        return scoped.maxByOrNull { (it.frame!!.width * it.frame!!.height) }
    }

    /** The window a node belongs to, by walking parents. */
    private fun windowRefOf(snapshot: Snapshot, node: Node): String? {
        var current: Node? = node
        while (current != null) {
            if (current.kind == dev.reticle.core.NodeKind.window) return current.ref
            current = current.parentRef?.let { snapshot.nodes[it] }
        }
        return null
    }

    private fun firstAvailableDirection(container: Node): String? {
        val info = container.scroll ?: return null
        return when {
            info.canScrollDown -> "down"
            info.canScrollRight -> "right"
            info.canScrollUp -> "up"
            info.canScrollLeft -> "left"
            else -> null
        }
    }

    private fun canScroll(container: Node, direction: String): Boolean {
        val info = container.scroll ?: return false
        return when (direction) {
            "down" -> info.canScrollDown
            "up" -> info.canScrollUp
            "left" -> info.canScrollLeft
            "right" -> info.canScrollRight
            else -> throw CliError("scroll-to: unknown --direction '$direction' (down/up/left/right)")
        }
    }

    /**
     * Swipe inside the container, moving content by ~60% of its extent. Staying
     * inside the container's own rect is what makes this land on the intended
     * scroller rather than on a page behind it.
     */
    private fun swipe(input: InputDispatcher, frame: Rect, direction: String) {
        val cx = (frame.x + frame.width / 2).toInt()
        val cy = (frame.y + frame.height / 2).toInt()
        val dx = (frame.width * 0.3).toInt()
        val dy = (frame.height * 0.3).toInt()
        when (direction) {
            // Content moves up when the finger moves up: that scrolls DOWN.
            "down" -> input.drag(cx, cy + dy, cx, cy - dy, SWIPE_DURATION_MS)
            "up" -> input.drag(cx, cy - dy, cx, cy + dy, SWIPE_DURATION_MS)
            "right" -> input.drag(cx + dx, cy, cx - dx, cy, SWIPE_DURATION_MS)
            "left" -> input.drag(cx - dx, cy, cx + dx, cy, SWIPE_DURATION_MS)
        }
    }

    /**
     * The container has no travel left in this direction: the selector is not in
     * this list. Said as a fact about the container, not as a verdict about the
     * app.
     */
    private fun describeExhausted(
        container: Node,
        selector: Selector,
        swipes: Int,
        direction: String?,
    ): String {
        val id = container.testId ?: container.resourceId ?: container.ref
        val dir = direction ?: "any direction"
        return "scroll-to reached the end of '$id' after $swipes swipe(s) $dir without resolving " +
            "'${selector.describe()}' (container now reports ${container.scroll?.describe() ?: "no travel"}). " +
            "Nothing bound under that selector came into view."
    }
}
