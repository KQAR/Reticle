package dev.reticle.cli

import dev.reticle.cli.platform.DeviceController
import dev.reticle.core.Node
import dev.reticle.core.PortMap
import dev.reticle.core.Point
import dev.reticle.core.RuntimeInfo
import dev.reticle.core.SemanticTree
import kotlinx.serialization.json.JsonObject

/**
 * Session-scoped record of the `adb forward`s the helper set up, so they can be
 * torn down when the helper exits. Forwards live on the (persistent) adb server,
 * which outlives the helper process, so without this they leak — one per distinct
 * package driven — and pile up across sessions. Idempotent per host port (the
 * port is derived deterministically from the package, so re-driving the same app
 * reuses one forward). Access is single-threaded: the helper serves RPC lines
 * sequentially and cleanup runs after that loop.
 */
internal object ForwardRegistry {
    private val forwards = LinkedHashMap<Int, DeviceController>()

    fun record(device: DeviceController, hostPort: Int) {
        forwards[hostPort] = device
    }

    /** Best-effort removal of every forward set up this session. */
    fun cleanup() {
        for ((hostPort, device) in forwards) {
            runCatching { device.removeForward(hostPort) }
        }
        forwards.clear()
    }
}

/** Runtime connection helpers shared by helper RPC command handlers. */
internal fun runtimeClientFor(
    device: DeviceController,
    pkg: String,
    params: JsonObject,
): RuntimeClient {
    val devicePort = params.intOrNull("port") ?: PortMap.derivePort(pkg)
    val hostPort = params.intOrNull("hostPort") ?: devicePort
    return RuntimeClient(device, hostPort, devicePort).also {
        it.setUpForward()
        ForwardRegistry.record(device, hostPort)
    }
}

internal fun assertHealthy(client: RuntimeClient, pkg: String) {
    when (val h = client.probe()) {
        is RuntimeHealth.Healthy -> if (h.info.packageName != pkg) {
            throw CliError("port conflict: served by '${h.info.packageName}', not '$pkg'")
        }
        is RuntimeHealth.Unreachable ->
            throw CliError("no Reticle runtime for '$pkg' (connection refused). Inject or launch first.")
        is RuntimeHealth.Unresponsive ->
            throw CliError("runtime for '$pkg' connected but did not respond (${h.detail})")
        is RuntimeHealth.Foreign ->
            throw CliError("port answered but not as a Reticle runtime (${h.sample})")
    }
}

/** Poll /runtime until the agent for [pkg] answers healthy, else throw. */
internal fun awaitRuntime(client: RuntimeClient, pkg: String, attempts: Int = 40): RuntimeInfo {
    repeat(attempts) {
        when (val health = client.probe()) {
            is RuntimeHealth.Healthy -> if (health.info.packageName == pkg) return health.info
            else -> {}
        }
        Thread.sleep(250)
    }
    throw CliError("timed out waiting for the runtime of '$pkg' to come up after inject")
}

/** A selector or raw point resolved to the exact screen coordinate adb will tap. */
internal data class ResolvedInputTarget(
    val point: Point,
    val source: String,
    val ref: String?,
)

internal fun resolveInputTarget(device: DeviceController, pkg: String, params: JsonObject): ResolvedInputTarget {
    params.str("alias")?.let { alias ->
        val entry = OutlineRenderer.resolveAlias(params.str("serial"), pkg, alias)
        // The cache records where the node WAS when the outline ran; re-resolve
        // against the live tree so a relayout between `ui outline` and `act`
        // doesn't land the tap on stale coordinates. The cached frame is the
        // fallback when the runtime can't answer or the node is gone.
        aliasLiveTarget(device, pkg, params, alias, entry)?.let { return it }
        val point = Point(entry.frame.centerX, entry.frame.centerY)
        return ResolvedInputTarget(point, "outline:$alias (cached frame)", entry.ref)
    }
    params.str("point")?.let {
        val (x, y) = parseXY(it)
        return ResolvedInputTarget(Point(x.toDouble(), y.toDouble()), "point", null)
    }
    val client = runtimeClientFor(device, pkg, params)
    assertHealthy(client, pkg)
    val snapshot = client.snapshot()
    val semantic = SemanticTree.build(snapshot)
    val selector = selectorFrom(params)
    val resolved = SelectorResolver(snapshot, semantic).resolve(selector)
        ?: throw CliError(SelectorDiagnostics.pointMiss(snapshot, selector))
    System.err.println("reticle-helper: resolved via ${resolved.source} -> ref=${resolved.ref}")
    return ResolvedInputTarget(resolved.point, resolved.source, resolved.ref)
}

/** A target plus whether its position was confirmed to have stopped moving. */
internal data class SettledInputTarget(val target: ResolvedInputTarget, val stable: Boolean)

/**
 * Re-resolve [first] until the selector lands on the same point twice in a row —
 * the target has stopped moving — or the budget runs out.
 *
 * Why a tap needs this at all. Resolution and dispatch are two steps, and between
 * them the screen can move: a popup or a sheet animating in is captured at an
 * intermediate rect, so the point is stale by the time the touch is synthesized and
 * the touch lands on the neighbouring row (measured on an emulator: a `PopupMenu`
 * tap aimed at "Delete item" the moment it was first captured fired "Rename"). This
 * is `act scroll-to`'s stabilize step, made available to `tap` on request: same
 * resolution path as the tap itself, no `isVisible` proxy — which is why it does not
 * revive the dropped `wait --for appears` proposal.
 *
 * Never blocks forever and never refuses to tap: on a lapsed budget it returns the
 * freshest target flagged `stable = false`, and the caller reports that as evidence.
 */
internal fun settleInputTarget(
    device: DeviceController,
    pkg: String,
    params: JsonObject,
    first: ResolvedInputTarget,
    budgetMs: Long = 2_000L,
    pollMs: Long = 150L,
): SettledInputTarget = settleTarget(first, budgetMs, pollMs) {
    // A target that vanishes mid-settle (a popup dismissed under us) is not a
    // failure of the tap yet — report the freshest point and let the dispatch, or
    // the caller's own verification, be the judge.
    runCatching { resolveInputTarget(device, pkg, params) }.getOrNull()
}

/** The settle loop itself, with the clock and the resolver injected so it is testable. */
internal fun settleTarget(
    first: ResolvedInputTarget,
    budgetMs: Long,
    pollMs: Long,
    nowMs: () -> Long = System::currentTimeMillis,
    sleep: (Long) -> Unit = { Thread.sleep(it) },
    resolve: () -> ResolvedInputTarget?,
): SettledInputTarget {
    val deadline = nowMs() + budgetMs
    var previous = first
    while (nowMs() < deadline) {
        sleep(pollMs)
        val current = resolve() ?: return SettledInputTarget(previous, false)
        if (samePoint(current.point, previous.point)) return SettledInputTarget(current, true)
        previous = current
    }
    return SettledInputTarget(previous, false)
}

private fun samePoint(a: Point, b: Point): Boolean =
    kotlin.math.abs(a.x - b.x) < 1.0 && kotlin.math.abs(a.y - b.y) < 1.0

/**
 * Re-resolve a cached outline entry against the live tree. Match by the
 * entry's stable selector (testId / resourceId / css) first, then by
 * label+role; when several nodes match (repeated list items), prefer the one
 * nearest the cached frame — that is the node the alias pointed at, wherever
 * the relayout moved it. Null when the runtime is unreachable or nothing
 * matches anymore (the caller falls back to the cached frame).
 */
private fun aliasLiveTarget(
    device: DeviceController,
    pkg: String,
    params: JsonObject,
    alias: String,
    entry: OutlineRenderer.Entry,
): ResolvedInputTarget? = runCatching {
    val client = runtimeClientFor(device, pkg, params)
    if (client.probe() !is RuntimeHealth.Healthy) return null
    val nearest = aliasLiveMatch(client.snapshot().nodes.values, entry) ?: return null
    val frame = nearest.frame!!
    ResolvedInputTarget(Point(frame.centerX, frame.centerY), "outline:$alias->live", nearest.ref)
}.getOrNull()

/**
 * The live node a cached outline entry points at, or null when it is gone.
 * Pure matching half of [aliasLiveTarget], separated so it can be tested
 * without a device.
 */
internal fun aliasLiveMatch(liveNodes: Collection<Node>, entry: OutlineRenderer.Entry): Node? {
    val nodes = liveNodes.filter { it.isVisible && it.frame != null }
    val matched = nodes.filter { node ->
        (entry.testId != null && node.testId == entry.testId) ||
            (entry.resourceId != null && node.resourceId == entry.resourceId) ||
            (entry.css != null && node.domCssSelector() == entry.css)
    }.ifEmpty {
        val label = entry.label ?: return null
        nodes.filter { (it.contentDescription ?: it.text) == label && (it.role ?: it.typeName) == entry.role }
    }
    return matched.minByOrNull { node ->
        val f = node.frame!!
        val dx = f.centerX - entry.frame.centerX
        val dy = f.centerY - entry.frame.centerY
        dx * dx + dy * dy
    }
}

/**
 * When a selector tap re-resolves before dispatching, and for how long.
 *
 * Split out from the act handler because it is the whole of the policy change and
 * the part worth pinning: resolution and dispatch are two steps, and between them
 * the screen can move. `--settle` was introduced for a target ANIMATING IN, but
 * the same staleness comes from a relayout caused by an EARLIER command — a
 * `type` that raised the keyboard, a `hide-keyboard`, a scroll — and a caller has
 * no cue to reach for a flag in that case. Measured on a physical device: a form
 * row resolved to a rect already 161px stale and the touch opened the sheet of the
 * row below it, reported as a plain success.
 *
 * So the confirm is the default, and the flags now mean:
 *  - nothing        -> confirm with a short budget (one agreeing re-resolve ends it);
 *  - `--settle`     -> this target IS animating; give it the full budget;
 *  - `--no-settle`  -> single-read dispatch, the pre-existing behaviour;
 *  - `--point`      -> nothing to re-resolve; never confirm.
 */
internal object TapSettlePolicy {
    /** Budget for the default confirm — bounds the animating case, not the common one. */
    const val CONFIRM_BUDGET_MS = 800L

    /** Budget for an explicit `--settle`, for a target known to be sliding in. */
    const val SETTLE_BUDGET_MS = 2_000L

    /** Whether to re-resolve before dispatch, and the budget to do it in. */
    data class Plan(val confirm: Boolean, val budgetMs: Long)

    fun plan(rawPoint: Boolean, settle: Boolean, noSettle: Boolean, timeoutMs: Int?): Plan {
        if (rawPoint || noSettle) return Plan(confirm = false, budgetMs = 0L)
        val budget = timeoutMs?.toLong() ?: if (settle) SETTLE_BUDGET_MS else CONFIRM_BUDGET_MS
        return Plan(confirm = true, budgetMs = budget)
    }

    /**
     * How far the confirm moved the tap point, as `dx,dy` — or null when it did not
     * move (whole pixels; a sub-pixel difference is not a relayout). Reported so the
     * confirm does not SILENTLY fix a stale rect: the caller reasoned about the
     * screen as it was before, and needs to know that changed.
     */
    fun movedBy(first: Point, dispatched: Point): String? {
        val dx = (dispatched.x - first.x).toInt()
        val dy = (dispatched.y - first.y).toInt()
        return if (dx == 0 && dy == 0) null else "$dx,$dy"
    }
}
