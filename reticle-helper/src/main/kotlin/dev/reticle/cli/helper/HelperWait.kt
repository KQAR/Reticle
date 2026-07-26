package dev.reticle.cli

import dev.reticle.cli.platform.DeviceController
import dev.reticle.core.CompactObservation
import dev.reticle.core.Selector
import dev.reticle.core.SemanticTree
import dev.reticle.core.Snapshot
import dev.reticle.core.WaitOutcome
import dev.reticle.core.WaitPredicate
import dev.reticle.core.WaitPredicateKind
import dev.reticle.core.WaitProbe
import dev.reticle.core.WaitSchedule
import dev.reticle.core.WaitVerdict
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * `act wait`: poll the live tree until a stated predicate holds, then report a
 * three-state answer with the evidence behind it.
 *
 * What this closes. Every other timing primitive here answers a different
 * question: `--verify` watches a node that must ALREADY resolve (so "tap, then a
 * new screen appears" is inexpressible), and `--settle` only watches whether a
 * point stopped moving. Without a wait, an agent crossing an async boundary —
 * a network call, a navigation transition — has nothing but a blind sleep, which
 * is where agent-driven verification goes flaky.
 *
 * The success test is [SelectorResolver] resolution, the same path `act` itself
 * uses — NOT `isVisible`. That distinction is why this exists at all: an earlier
 * `wait --for appears` proposal was dropped over the `isVisible` proxy (see
 * [HelperScrollTo] and `settleInputTarget`), and resolution carries the guarantee
 * the proxy could not — a `resolved` wait means the very next `act` resolves the
 * same way. Visibility and occlusion are reported as caveats instead.
 *
 * The classification itself lives in `reticle-core` ([WaitVerdict.classify]) so
 * the iOS host answers identically; only the polling I/O is here.
 */
internal object HelperWait {

    fun run(device: DeviceController, pkg: String, params: JsonObject): JsonObject {
        val predicate = predicateFrom(params)
        val timeoutMs = (params.intOrNull("timeoutMs") ?: WaitSchedule.DEFAULT_TIMEOUT_MS.toInt()).toLong()
        val quietMs = (params.intOrNull("quietMs") ?: WaitSchedule.DEFAULT_QUIET_MS.toInt()).toLong()
        val client = runtimeClientFor(device, pkg, params)
        assertHealthy(client, pkg)

        val started = System.currentTimeMillis()
        val deadline = started + timeoutMs
        var polls = 0
        var treeChanges = 0
        var lastDigest: String? = null
        var lastChangeAt = started
        var probe = probeOnce(client, predicate)

        while (true) {
            polls++
            if (lastDigest != null && probe.digest != lastDigest) {
                treeChanges++
                lastChangeAt = System.currentTimeMillis()
            }
            lastDigest = probe.digest

            val quiet = polls >= 2 && (System.currentTimeMillis() - lastChangeAt) >= quietMs
            // An idle wait is DONE the moment the screen goes quiet — it must not
            // burn the rest of the budget once its whole predicate is satisfied.
            val satisfied = if (predicate.kind == WaitPredicateKind.idle) quiet else probe.satisfies(predicate)
            if (satisfied || System.currentTimeMillis() >= deadline) {
                val verdict = WaitVerdict.classify(predicate, probe, quiet)
                return render(
                    predicate = predicate,
                    verdict = verdict,
                    probe = probe,
                    elapsedMs = System.currentTimeMillis() - started,
                    timeoutMs = timeoutMs,
                    polls = polls,
                    treeChanges = treeChanges,
                    sinceLastChangeMs = System.currentTimeMillis() - lastChangeAt,
                )
            }

            val elapsed = System.currentTimeMillis() - started
            val delay = WaitSchedule.delayMs(elapsed)
            // Never sleep past the deadline: a 500ms backoff on a budget with 80ms
            // left would report a timeout later than the caller asked for.
            Thread.sleep(delay.coerceAtMost((deadline - System.currentTimeMillis()).coerceAtLeast(1)))
            probe = probeOnce(client, predicate)
        }
    }

    /**
     * Build the predicate the caller stated.
     *
     * `--for <token>` reuses `--verify`'s token grammar rather than inventing a
     * second spelling; the ordinary `--test-id` / `--css` / ... flags work too.
     */
    internal fun predicateFrom(params: JsonObject): WaitPredicate {
        val token = params.str("for")
        val fromToken = token
            ?.takeIf { it != "idle" }
            ?.let { parseVerifyToken(it, null, null, null, null) }
        val selector = fromToken ?: selectorFrom(params).takeIf {
            it.testId != null || it.resourceId != null || it.cssSelector != null ||
                it.ref != null || it.label != null
        }
        val gone = params.bool("gone")
        val textContains = params.str("textContains")
        val idleRequested = params.bool("idle") || token == "idle"

        if (idleRequested) {
            if (selector != null) {
                throw CliError(
                    "wait --idle waits for the SCREEN to stop changing, so it takes no selector. " +
                        "Drop the selector, or drop --idle to wait for that selector instead."
                )
            }
            if (gone || textContains != null) {
                throw CliError("wait --idle takes neither --gone nor --text")
            }
            return WaitPredicate(WaitPredicateKind.idle)
        }
        // These two are checked BEFORE the missing-predicate error, so a caller who
        // passed something unusable gets told why it is unusable rather than the
        // generic "needs a predicate".
        if (params.str("point") != null) {
            throw CliError(
                "wait cannot take --point: a raw coordinate always 'resolves', so there is nothing to wait for"
            )
        }
        if (params.str("alias") != null) {
            throw CliError(
                "wait cannot take --alias: an outline alias describes the screen it was captured on, " +
                    "which is the screen a wait expects to change. Use --test-id / --resource-id / --css / --ref."
            )
        }
        if (selector == null) {
            throw CliError(
                "wait needs a predicate: --for '#testId' (or --test-id / --resource-id / --css / --ref / --label), " +
                    "optionally with --gone or --text <substring>; or --idle to wait for the screen to settle"
            )
        }
        if (gone && textContains != null) {
            throw CliError("wait takes --gone or --text, not both")
        }
        return when {
            gone -> WaitPredicate(WaitPredicateKind.gone, selector)
            textContains != null -> WaitPredicate(WaitPredicateKind.text, selector, textContains)
            else -> WaitPredicate(WaitPredicateKind.appear, selector)
        }
    }

    /** One poll: capture, resolve the way `act` resolves, and read the screen-level markers. */
    private fun probeOnce(client: RuntimeClient, predicate: WaitPredicate): WaitProbe {
        val snapshot = client.snapshot()
        val compact = CompactObservation.from(snapshot)
        // Screen-level half comes from reticle-core, shared with the iOS host.
        val base = WaitProbe.screenState(snapshot, compact)
        val selector = predicate.selector ?: return base

        // The same resolution `act` performs. Ambiguity is CARRIED, not thrown:
        // a label that turns ambiguous mid-wait should end the wait with an
        // explanation, not an exception from inside a poll loop.
        val resolved = try {
            SelectorResolver(snapshot, SemanticTree.build(snapshot)).resolve(selector)
        } catch (_: RegionMissError) {
            // The node is there but the requested phrase is not (yet): an honest
            // negative, not an unknowable. Distinct from the ambiguity below —
            // conflating them would report "refusing to guess" for a phrase that
            // simply has not rendered.
            return base
        } catch (_: CliError) {
            return base.copy(ambiguous = true)
        } ?: return base

        val node = resolved.ref?.let { snapshot.nodes[it] }
        val item = resolved.ref?.let { ref -> compact.items.firstOrNull { it.ref == ref } }
        return base.copy(
            resolved = true,
            source = resolved.source,
            ref = resolved.ref,
            // A node absent from the compact view is one the compact filter dropped
            // (it keeps visible nodes only), so treat missing-from-compact as not
            // visible rather than defaulting to true.
            visible = node?.isVisible ?: (item != null),
            observedText = node?.text ?: node?.contentDescription,
            occludedBy = item?.occludedBy,
        )
    }

    private fun render(
        predicate: WaitPredicate,
        verdict: WaitVerdict,
        probe: WaitProbe,
        elapsedMs: Long,
        timeoutMs: Long,
        polls: Int,
        treeChanges: Int,
        sinceLastChangeMs: Long,
    ): JsonObject = buildJsonObject {
        put("gesture", "wait")
        put("predicate", predicate.describe())
        put("outcome", verdict.outcome.name)
        if (verdict.reasons.isNotEmpty()) {
            put("reasons", buildJsonArray { verdict.reasons.forEach { add(it) } })
        }
        if (verdict.caveats.isNotEmpty()) {
            put("caveats", buildJsonArray { verdict.caveats.forEach { add(it) } })
        }
        put("elapsedMs", elapsedMs)
        put("timeoutMs", timeoutMs)
        put("polls", polls)
        put("treeChanges", treeChanges)
        put("sinceLastChangeMs", sinceLastChangeMs)
        probe.source?.let { put("source", it) }
        probe.ref?.let { put("ref", it) }
        probe.observedText?.let { put("observedText", it) }
        val next = nextSteps(predicate, verdict, probe)
        if (next.isNotEmpty()) put("next", buildJsonArray { next.forEach { add(it) } })
    }

    /**
     * Concrete follow-ups, so an `unknowable` hands back a tactic instead of just a
     * complaint. Deliberately commands, not prose: the caller is usually an agent.
     */
    private fun nextSteps(
        predicate: WaitPredicate,
        verdict: WaitVerdict,
        probe: WaitProbe,
    ): List<String> {
        val out = LinkedHashSet<String>()
        val selector = predicate.selector?.let { s ->
            s.testId?.let { "--test-id $it" }
                ?: s.resourceId?.let { "--resource-id $it" }
                ?: s.cssSelector?.let { "--css '$it'" }
                ?: s.ref?.let { "--ref $it" }
                ?: s.label?.let { "--label '$it'" }
        }
        val marks = verdict.reasons + verdict.caveats
        // Order matters: the most specific blocker first. A caller (usually an
        // agent) acts on the first line, so a generic "try scrolling" must never
        // outrank "the DOM is unreadable right now" — measured advising
        // `scroll-to --css` for an element behind a blocking JS modal.
        if (marks.any { it == CompactObservation.OCCLUDER_KEYBOARD || it.endsWith(":keyboard") }) {
            out.add("act hide-keyboard")
        }
        if (marks.contains(WaitVerdict.REASON_WINDOW_UNFOCUSED)) {
            // No command can dismiss another process's window from in here.
            out.add("resolve the foreground system window first (it is in no node of this tree)")
        }
        if (marks.contains(WaitVerdict.REASON_DOM_UNAVAILABLE)) {
            out.add("dismiss the blocking JS modal, then re-run this wait")
        }
        if (marks.contains(WaitVerdict.REASON_DOM_UNSUPPORTED_KERNEL)) {
            out.add("target it as a plain view (--test-id / --point); --css can never match this kernel")
        }
        if (marks.contains(WaitVerdict.REASON_SELECTOR_AMBIGUOUS)) {
            out.add("narrow the selector (--test-id / --resource-id / --ref)")
        }
        // Scrolling can only ever produce a NATIVE node; a DOM element is not
        // brought into being by dragging a native container, so a css predicate
        // never gets this advice.
        if (marks.any { it.contains("scroll:") } && selector != null &&
            predicate.selector?.cssSelector == null
        ) {
            out.add("act scroll-to $selector")
        }
        if (marks.contains(WaitVerdict.REASON_TREE_STILL_CHANGING)) {
            out.add("raise --timeout, or wait for the screen to settle first (act wait --idle)")
        }
        if (verdict.outcome == WaitOutcome.absent) {
            out.add("ui compact --live to see what IS on screen")
        }
        return out.toList()
    }
}
