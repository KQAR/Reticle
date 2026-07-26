package dev.reticle.core

import kotlinx.serialization.Serializable

/**
 * `act wait`: the predicate a caller states, and the three-state answer.
 *
 * Why this lives in reticle-core, as pure functions over a [WaitProbe]: the poll
 * loop itself is per-platform I/O (Kotlin helper for Android, Swift host for iOS),
 * but the *meaning* of the answer must not be written twice — `scroll-to`'s
 * settle logic already drifted that way. Everything below is decided from a
 * snapshot-derived probe, so the same table pins both implementations
 * (reticle-protocol/fixtures/wait-classification.cases.json).
 *
 * The design rule this file exists to enforce: **existence is three-state, not
 * two.** "I did not find it" and "I could not have seen it" are different
 * observations, and collapsing them is how a runtime observer lies — an agent
 * that reads `absent` will conclude the feature is broken, when the truth was
 * that a keyboard covered it, a list had not bound it, or another process's
 * window owned the screen. [WaitOutcome.unknowable] is the honest third answer.
 */
@Serializable
enum class WaitPredicateKind {
    /**
     * The selector resolves through the SAME path an `act` would use
     * (semantic-first, then view frames). Deliberately not `isVisible`: see
     * [WaitProbe.resolved].
     */
    appear,

    /** The selector no longer resolves through that path. */
    gone,

    /** The selector resolves and its text/label contains [WaitPredicate.textContains]. */
    text,

    /** No selector: wait for the screen itself to stop changing. */
    idle,
}

/**
 * What the caller said they were waiting for. Echoed back verbatim in the result
 * so "what was being waited on" is never something the reader has to infer.
 */
@Serializable
data class WaitPredicate(
    val kind: WaitPredicateKind,
    /** Null only for [WaitPredicateKind.idle]. */
    val selector: Selector? = null,
    /** Set only for [WaitPredicateKind.text]. */
    val textContains: String? = null,
) {
    /**
     * Stable one-line rendering. Reuses [Selector.describe] rather than
     * re-spelling the selector grammar, so a new selector kind shows up here
     * automatically instead of silently rendering as "?".
     */
    fun describe(): String {
        val sel = selector?.describe()
        return when (kind) {
            WaitPredicateKind.idle -> "idle"
            WaitPredicateKind.appear -> "appear ${sel ?: "?"}"
            WaitPredicateKind.gone -> "gone ${sel ?: "?"}"
            WaitPredicateKind.text -> "text ${sel ?: "?"} contains ${textContains?.let { "\"$it\"" } ?: "?"}"
        }
    }
}

/**
 * One poll's worth of observation, derived from a snapshot + its compact form.
 *
 * Everything here is already computed by [CompactObservation.from] — occlusion at
 * the tap point, scroll travel, the DOM markers — so a probe adds no new capture
 * capability, it just names the inputs the verdict is allowed to depend on.
 */
@Serializable
data class WaitProbe(
    /**
     * Did the selector resolve through the same resolution path an `act` uses —
     * semantic tree first, view frames as fallback?
     *
     * This is THE success test, and the choice is load-bearing. An earlier
     * `wait --for appears` proposal was dropped in this repo precisely because it
     * tested `isVisible`, a weak per-platform proxy: two platforms disagree on what
     * a zero-alpha or clipped view reports, and "visible" says nothing about
     * whether the next command can target the thing. Resolution is the same test
     * `act scroll-to` and `tap --settle` justified themselves with, and it carries
     * an operational guarantee those proxies cannot:
     *
     *     a `resolved` wait means the very next `act` resolves the same way.
     *
     * Visibility and occlusion are still reported — as caveats, never as the
     * verdict, because "can I target it" and "can the user see it" are different
     * questions and this file's whole job is to stop conflating such pairs.
     */
    val resolved: Boolean = false,
    /** Which path resolved it ("semantic:testId", "view", "dom:css", …). Evidence, as `act` reports it. */
    val source: String? = null,
    /** The resolved node's ref, when there was one. */
    val ref: String? = null,
    /** Was the resolved node visible? Drives a caveat, never the outcome. */
    val visible: Boolean = true,
    /** The resolved node's text, else its label. Reported so a `text` miss shows what WAS there. */
    val observedText: String? = null,
    /** What covers the resolved node's tap point, if anything: a window ref or "keyboard". */
    val occludedBy: String? = null,
    /**
     * Quiescence digest of the whole screen. Two consecutive equal digests mean
     * nothing observable moved; that is what lets `absent` be established at all.
     */
    val digest: String = "",
    /** False when another process's window holds input focus. Null when unprobed. */
    val windowFocused: Boolean? = null,
    /** Some web view on screen could not be read at this moment. */
    val domUnavailable: Boolean = false,
    /** Some web view on screen is a third-party kernel with no DOM bridge at all. */
    val domKernelUnsupported: Boolean = false,
    /**
     * Scrollable containers on screen that still have travel left, as
     * "ref:up,down". Non-empty means a row may simply not be bound yet.
     */
    val scrollTravel: List<String> = emptyList(),
    /**
     * The selector matched several nodes and the resolver refused to pick one.
     * Carried rather than thrown so a label that turns ambiguous mid-wait ends the
     * wait with an explanation instead of an exception.
     */
    val ambiguous: Boolean = false,
) {
    companion object {
        /**
         * The screen-level half of a probe — everything that does not depend on the
         * per-platform selector resolver. Shared with the Swift twin so the two
         * hosts cannot drift on the digest's inputs (which decides quiescence) or
         * on how a scroll-travel reason is spelled (which an agent reads).
         */
        fun screenState(snapshot: Snapshot, compact: CompactObservation): WaitProbe = WaitProbe(
            digest = digestOf(compact),
            windowFocused = compact.screen.windowFocused,
            domUnavailable = compact.items.any { it.domUnavailable },
            domKernelUnsupported = compact.items.any { it.domKernelUnsupported },
            scrollTravel = scrollTravelOf(snapshot, compact),
        )

        /**
         * Scrollable containers with travel left, as "#id scroll:down" — scoped to
         * the TOPMOST window.
         *
         * Why the scoping. A background window's scroller can never bring the thing
         * you are waiting for into view, and citing it was measured doing real harm:
         * waiting for a DOM element behind a blocking JS modal reported
         * `#home.scroller scroll:down` and advised `act scroll-to --css '#js-alert'`
         * — advice an agent might follow, for a container that has nothing to do
         * with the target. On a screen with any scrollable at all, it also made
         * `absent` almost unreachable, since every miss picked up a scroll reason.
         *
         * Scoping to the top window keeps the case that matters (a recycling list
         * in the window you are actually looking at) and drops the noise.
         */
        fun scrollTravelOf(snapshot: Snapshot, compact: CompactObservation): List<String> {
            val windowRefs = snapshot.root()?.children
                ?.filter { snapshot.nodes[it]?.kind == NodeKind.window }
                ?: emptyList()
            // Application children are the window roots in stacking order, so the
            // last visible one is on top. With no window nodes at all (some iOS
            // trees), fall back to every scrollable rather than silently none.
            val topWindow = windowRefs.lastOrNull { snapshot.nodes[it]?.isVisible == true }

            fun windowOf(ref: String): String? {
                var current = snapshot.nodes[ref]
                while (current != null) {
                    if (current.kind == NodeKind.window) return current.ref
                    current = current.parentRef?.let { snapshot.nodes[it] }
                }
                return null
            }

            return compact.items
                .mapNotNull { item ->
                    val scroll = item.scroll?.takeIf { it.isScrollable } ?: return@mapNotNull null
                    if (topWindow != null && windowOf(item.ref) != topWindow) return@mapNotNull null
                    val id = item.testId?.let { "#$it" } ?: item.resourceId?.let { "@$it" } ?: item.ref
                    "$id ${scroll.describe()}"
                }
                .distinct()
        }

        /**
         * The canonical string a quiescence digest hashes: what counts as "the
         * screen changed".
         *
         * Built from the compact view rather than the raw snapshot because the raw
         * tree carries per-capture noise, and `capturedAtMillis` alone would make
         * every poll look like a change. Keyboard and focus are folded in because a
         * keyboard sliding up is a change an agent cares about even when no node
         * moved.
         */
        fun digestInput(compact: CompactObservation): String {
            val sb = StringBuilder(compact.items.size * 48)
            compact.items.forEach { item ->
                sb.append(item.ref).append('|')
                    .append(item.role).append('|')
                    .append(item.label ?: "").append('|')
                    .append(
                        item.frame?.let {
                            "${it.x.toInt()},${it.y.toInt()},${it.width.toInt()}x${it.height.toInt()}"
                        } ?: ""
                    )
                    .append('|').append(item.isEnabled)
                    .append('|').append(item.occludedBy ?: "")
                    .append('\n')
            }
            compact.screen.keyboard?.let { kb ->
                sb.append("kb:").append(kb.visible).append('|')
                    .append(kb.frame?.let { "${it.y.toInt()}x${it.height.toInt()}" } ?: "")
                    .append('\n')
            }
            sb.append("focus:").append(compact.screen.windowFocused ?: "?")
            return sb.toString()
        }

        /**
         * Digest of [digestInput]. The hash itself is only ever compared against
         * another digest from the SAME process, so the two platforms need the same
         * inputs but not the same hash function.
         */
        fun digestOf(compact: CompactObservation): String =
            Integer.toHexString(digestInput(compact).hashCode())
    }

    /** Is the stated predicate satisfied by THIS probe? Pure, no time involved. */
    fun satisfies(predicate: WaitPredicate): Boolean = when (predicate.kind) {
        // `idle` is decided by quiescence across polls, never by one probe.
        WaitPredicateKind.idle -> false
        WaitPredicateKind.appear -> resolved
        WaitPredicateKind.gone -> !resolved
        WaitPredicateKind.text ->
            resolved && predicate.textContains != null &&
                observedText?.contains(predicate.textContains) == true
    }
}

/** The three-state answer. Never a claim about whether the app is CORRECT. */
@Serializable
enum class WaitOutcome {
    /** The predicate held. A fact. */
    resolved,

    /** The predicate did not hold, and nothing prevented seeing it. An honest negative. */
    absent,

    /**
     * The predicate did not hold, but the screen was in a state where it could
     * not have been observed. NOT a negative — the caller must switch tactics,
     * not conclude anything about the app.
     */
    unknowable,
}

/**
 * The verdict plus its justification.
 *
 * [reasons] explains an [WaitOutcome.unknowable] (or why `absent` is trustworthy:
 * empty). [caveats] carries facts that do not change the outcome but that a
 * caller must not ignore — chiefly a satisfied `appear` whose node is occluded
 * (it exists, and a tap would still land on the occluder) and a satisfied `gone`
 * on a screen that can still scroll (recycled out of the bound window is
 * indistinguishable from removed).
 */
@Serializable
data class WaitVerdict(
    val outcome: WaitOutcome,
    val reasons: List<String> = emptyList(),
    val caveats: List<String> = emptyList(),
) {
    companion object {
        const val REASON_TREE_STILL_CHANGING = "tree-still-changing"
        const val REASON_WINDOW_UNFOCUSED = "window-unfocused"
        const val REASON_DOM_UNAVAILABLE = "dom:unavailable"
        const val REASON_DOM_UNSUPPORTED_KERNEL = "dom:unsupported-kernel"

        /**
         * A `--label` predicate matched several nodes. The resolver refuses to
         * guess (ambiguity is an error, never a silent first-match), so the wait
         * cannot answer either — an ambiguous label is unknowable, not absent.
         */
        const val REASON_SELECTOR_AMBIGUOUS = "selector-ambiguous"
        const val CAVEAT_OCCLUDED_PREFIX = "occluded-by:"
        const val CAVEAT_MAY_BE_UNBOUND = "may-be-unbound-not-removed"

        /**
         * The selector resolves, so the next `act` can target it — but it is not
         * visible. Targetability and visibility are different facts; this is where
         * the second one gets said instead of silently changing the verdict.
         */
        const val CAVEAT_RESOLVED_NOT_VISIBLE = "resolved-but-not-visible"

        /**
         * Decide the outcome from the last probe plus whether the screen ever
         * settled. [quiet] is the caller's quiescence finding: two consecutive
         * probes with an equal [WaitProbe.digest] within the budget.
         *
         * Order matters only for readability — every blocking reason is collected,
         * because "the keyboard covers it AND the list can still scroll" is more
         * useful to a caller than the first one found.
         */
        fun classify(predicate: WaitPredicate, probe: WaitProbe, quiet: Boolean): WaitVerdict {
            if (predicate.kind == WaitPredicateKind.idle) {
                // Nobody stated an expectation about content, so there is no
                // negative to report: either it settled, or it never did.
                return if (quiet) {
                    WaitVerdict(WaitOutcome.resolved, caveats = focusCaveats(probe))
                } else {
                    WaitVerdict(WaitOutcome.unknowable, reasons = listOf(REASON_TREE_STILL_CHANGING))
                }
            }

            if (probe.satisfies(predicate)) {
                val caveats = ArrayList<String>()
                // Targetability is satisfied; being visible and being un-covered
                // are separate questions, and this is the only place they get
                // said. Neither downgrades a `resolved` — that would conflate
                // "can the next act target it" with "can the user see it", which
                // is exactly the conflation this type exists to avoid.
                if (predicate.kind != WaitPredicateKind.gone) {
                    if (!probe.visible) caveats.add(CAVEAT_RESOLVED_NOT_VISIBLE)
                    probe.occludedBy?.let { caveats.add("$CAVEAT_OCCLUDED_PREFIX$it") }
                } else if (probe.scrollTravel.isNotEmpty()) {
                    // A `gone` that came true on a scrollable screen is ambiguous:
                    // a recycling list unbinds rows that are merely off-screen.
                    caveats.add(CAVEAT_MAY_BE_UNBOUND)
                    caveats.addAll(probe.scrollTravel)
                }
                caveats.addAll(focusCaveats(probe))
                return WaitVerdict(WaitOutcome.resolved, caveats = caveats)
            }

            val reasons = ArrayList<String>()
            // Never settled: the budget ran out mid-animation/mid-load, so "not
            // there" was never established in the first place.
            if (!quiet) reasons.add(REASON_TREE_STILL_CHANGING)
            // The resolver refused to guess between several matches, so this wait
            // has no answer to give — not a negative.
            if (probe.ambiguous) reasons.add(REASON_SELECTOR_AMBIGUOUS)
            // Another process owns the screen. Nothing about this app's tree is a
            // statement about what the user is looking at.
            if (probe.windowFocused == false) reasons.add(REASON_WINDOW_UNFOCUSED)
            if (predicate.selector?.cssSelector != null) {
                // A CSS predicate can only ever be answered by a readable DOM.
                if (probe.domUnavailable) reasons.add(REASON_DOM_UNAVAILABLE)
                if (probe.domKernelUnsupported) reasons.add(REASON_DOM_UNSUPPORTED_KERNEL)
            }
            // A row a recycling/lazy list has not bound has no node at all, so its
            // absence is not evidence.
            //
            // Gated on never having RESOLVED a node to read, not merely on the
            // predicate kind: a `text` miss where the node resolved is a real
            // reading of a real node, and no amount of scrolling changes the text
            // it holds. Letting travel cloud that would make every text predicate
            // on a scrollable screen permanently unknowable.
            if (predicate.kind != WaitPredicateKind.gone && !probe.resolved && probe.scrollTravel.isNotEmpty()) {
                reasons.addAll(probe.scrollTravel)
            }

            return if (reasons.isEmpty()) {
                WaitVerdict(WaitOutcome.absent)
            } else {
                WaitVerdict(WaitOutcome.unknowable, reasons = reasons)
            }
        }

        /**
         * Lost focus is a caveat even on success: the predicate held in this app's
         * tree, but another process's window is on top of it.
         */
        private fun focusCaveats(probe: WaitProbe): List<String> =
            if (probe.windowFocused == false) listOf(REASON_WINDOW_UNFOCUSED) else emptyList()
    }
}

/*
 * There is deliberately no `WaitResult` model here.
 *
 * Both hosts assemble the reply in their own RPC representation — the Kotlin
 * helper builds a `JsonObject`, the Swift host a `[String: Any]` — so a
 * @Serializable mirror of that shape would be a type that CLAIMS to be the wire
 * format while nothing encodes through it: a drift trap of exactly the kind this
 * file exists to prevent. The reply's key set is pinned where it is actually
 * produced and consumed instead (`ActWaitCommandTests` for what the CLI reads,
 * `IosWaitTests` for what the iOS runner emits).
 *
 * What the shape guarantees, wherever it is built: `outcome` is a FIELD, and a
 * timeout still answers `{"ok": true, …}` — a predicate that did not come true is
 * an observation, not a tool failure. The exit code is a lossy projection of that
 * field for shell/CI consumers only.
 */

/**
 * The poll schedule.
 *
 * Backoff, because a wait's budget is an order of magnitude larger than
 * `--verify`'s: every poll is a full in-process tree walk plus an adb-forward
 * round trip, so a flat 150ms over 30s would be ~200 tree walks. Dense early
 * (most waits resolve in the first second), sparse later.
 */
object WaitSchedule {
    const val DEFAULT_TIMEOUT_MS = 10_000L
    const val DEFAULT_QUIET_MS = 400L

    /** Delay before the next poll, given how long we have already waited. */
    fun delayMs(elapsedMs: Long): Long = when {
        elapsedMs < 2_000 -> 100
        elapsedMs < 5_000 -> 250
        else -> 500
    }
}
