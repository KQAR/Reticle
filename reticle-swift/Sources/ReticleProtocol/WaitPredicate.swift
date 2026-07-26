import Foundation

/// `act wait`: the predicate a caller states, and the three-state answer.
/// Mirrors reticle-core's `WaitPredicate.kt`.
///
/// Why the classification lives in the protocol package rather than in the host:
/// the poll loop is per-platform I/O (the Kotlin helper drives Android, the Swift
/// host drives iOS), but the *meaning* of the answer must not be written twice.
/// `scroll-to`'s settle logic already drifted that way — the Kotlin
/// `HelperScrollTo` and the Swift `IosHelperClient.scrollTo` are two hand-written
/// implementations of one idea. Everything here is decided from a snapshot-derived
/// probe, and `reticle-protocol/fixtures/wait-classification.cases.json` pins both
/// sides to one table.
///
/// The rule this file enforces: **existence is three-state, not two.** "I did not
/// find it" and "I could not have seen it" are different observations, and
/// collapsing them is how a runtime observer lies.
public enum WaitPredicateKind: String, Codable, Sendable {
    /// The selector resolves through the SAME path an `act` would use.
    /// Deliberately not `isVisible` — see `WaitProbe.resolved`.
    case appear
    /// The selector no longer resolves through that path.
    case gone
    /// The selector resolves and its text/label contains `WaitPredicate.textContains`.
    case text
    /// No selector: wait for the screen itself to stop changing.
    case idle
}

/// What the caller said they were waiting for. Echoed back verbatim in the result
/// so "what was being waited on" is never something the reader has to infer.
public struct WaitPredicate: Codable, Sendable {
    public var kind: WaitPredicateKind
    /// Nil only for `.idle`.
    public var selector: Selector?
    /// Set only for `.text`.
    public var textContains: String?

    public init(kind: WaitPredicateKind, selector: Selector? = nil, textContains: String? = nil) {
        self.kind = kind
        self.selector = selector
        self.textContains = textContains
    }

    /// Stable one-line rendering. Delegates to `Selector.describe()` rather than
    /// re-spelling the selector grammar, so a new selector kind shows up here
    /// automatically instead of silently rendering as "?".
    public func describe() -> String {
        let sel = selector?.describe()
        switch kind {
        case .idle: return "idle"
        case .appear: return "appear \(sel ?? "?")"
        case .gone: return "gone \(sel ?? "?")"
        case .text:
            let needle = textContains.map { "\"\($0)\"" } ?? "?"
            return "text \(sel ?? "?") contains \(needle)"
        }
    }
}

/// One poll's worth of observation, derived from a snapshot + its compact form.
///
/// Everything here is already computed by `CompactObservation.from` — occlusion at
/// the tap point, scroll travel, the DOM markers — so a probe adds no new capture
/// capability, it just names the inputs the verdict may depend on.
public struct WaitProbe: Codable, Sendable {
    /// Did the selector resolve through the same resolution path an `act` uses —
    /// semantic tree first, view frames as fallback?
    ///
    /// This is THE success test, and the choice is load-bearing. An earlier
    /// `wait --for appears` proposal was dropped in this repo precisely because it
    /// tested `isVisible`, a weak per-platform proxy: two platforms disagree on
    /// what a zero-alpha or clipped view reports, and "visible" says nothing about
    /// whether the next command can target the thing. Resolution is the test
    /// `act scroll-to` and `tap --settle` justified themselves with, and it carries
    /// a guarantee those proxies cannot:
    ///
    ///     a `resolved` wait means the very next `act` resolves the same way.
    ///
    /// Visibility and occlusion are still reported — as caveats, never as the
    /// verdict.
    public var resolved: Bool
    /// Which path resolved it ("semantic:testId", "view", "dom:css", …).
    public var source: String?
    /// The resolved node's ref, when there was one.
    public var ref: String?
    /// Was the resolved node visible? Drives a caveat, never the outcome.
    public var visible: Bool
    /// The resolved node's text, else its label. Reported so a `text` miss shows
    /// what WAS there.
    public var observedText: String?
    /// What covers the resolved node's tap point: a window ref or "keyboard".
    public var occludedBy: String?
    /// Quiescence digest of the whole screen. Two consecutive equal digests mean
    /// nothing observable moved; that is what lets `absent` be established at all.
    public var digest: String
    /// False when another process's window holds input focus. Nil when unprobed.
    public var windowFocused: Bool?
    /// Some web view on screen could not be read at this moment.
    public var domUnavailable: Bool
    /// Some web view on screen is a third-party kernel with no DOM bridge at all.
    public var domKernelUnsupported: Bool
    /// Scrollable containers on screen that still have travel left, as
    /// "ref scroll:up,down". Non-empty means a row may simply not be bound yet.
    public var scrollTravel: [String]
    /// The selector matched several nodes and the resolver refused to pick one.
    public var ambiguous: Bool

    public init(
        resolved: Bool = false,
        source: String? = nil,
        ref: String? = nil,
        visible: Bool = true,
        observedText: String? = nil,
        occludedBy: String? = nil,
        digest: String = "",
        windowFocused: Bool? = nil,
        domUnavailable: Bool = false,
        domKernelUnsupported: Bool = false,
        scrollTravel: [String] = [],
        ambiguous: Bool = false
    ) {
        self.resolved = resolved
        self.source = source
        self.ref = ref
        self.visible = visible
        self.observedText = observedText
        self.occludedBy = occludedBy
        self.digest = digest
        self.windowFocused = windowFocused
        self.domUnavailable = domUnavailable
        self.domKernelUnsupported = domKernelUnsupported
        self.scrollTravel = scrollTravel
        self.ambiguous = ambiguous
    }

    // Decoding must match the Kotlin defaults exactly, because the shared fixture
    // table omits every field at its default value.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
        source = try c.decodeIfPresent(String.self, forKey: .source)
        ref = try c.decodeIfPresent(String.self, forKey: .ref)
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        observedText = try c.decodeIfPresent(String.self, forKey: .observedText)
        occludedBy = try c.decodeIfPresent(String.self, forKey: .occludedBy)
        digest = try c.decodeIfPresent(String.self, forKey: .digest) ?? ""
        windowFocused = try c.decodeIfPresent(Bool.self, forKey: .windowFocused)
        domUnavailable = try c.decodeIfPresent(Bool.self, forKey: .domUnavailable) ?? false
        domKernelUnsupported = try c.decodeIfPresent(Bool.self, forKey: .domKernelUnsupported) ?? false
        scrollTravel = try c.decodeIfPresent([String].self, forKey: .scrollTravel) ?? []
        ambiguous = try c.decodeIfPresent(Bool.self, forKey: .ambiguous) ?? false
    }

    /// The screen-level half of a probe — everything that does not depend on the
    /// per-platform selector resolver. Shared with the Kotlin twin so the two hosts
    /// cannot drift on the digest's inputs (which decides quiescence) or on how a
    /// scroll-travel reason is spelled (which an agent reads).
    public static func screenState(_ snapshot: Snapshot, _ compact: CompactObservation) -> WaitProbe {
        WaitProbe(
            digest: digestOf(compact),
            windowFocused: compact.screen.windowFocused,
            domUnavailable: compact.items.contains { $0.domUnavailable },
            domKernelUnsupported: compact.items.contains { $0.domKernelUnsupported },
            scrollTravel: scrollTravelOf(snapshot, compact)
        )
    }

    /// Scrollable containers with travel left, as "#id scroll:down" — scoped to the
    /// TOPMOST window.
    ///
    /// Why the scoping. A background window's scroller can never bring the thing you
    /// are waiting for into view, and citing it was measured doing real harm: waiting
    /// for a DOM element behind a blocking JS modal reported `#home.scroller
    /// scroll:down` and advised `act scroll-to --css '#js-alert'` — advice an agent
    /// might follow, for a container with nothing to do with the target. On a screen
    /// with any scrollable at all, it also made `absent` almost unreachable.
    public static func scrollTravelOf(_ snapshot: Snapshot, _ compact: CompactObservation) -> [String] {
        let windowRefs = (snapshot.nodes[snapshot.rootRef]?.children ?? [])
            .filter { snapshot.nodes[$0]?.kind == .window }
        // Window roots are in stacking order, so the last visible one is on top.
        // With no window nodes at all, fall back to every scrollable rather than
        // silently none.
        let topWindow = windowRefs.last { snapshot.nodes[$0]?.isVisible == true }

        func windowOf(_ ref: String) -> String? {
            var current = snapshot.nodes[ref]
            while let node = current {
                if node.kind == .window { return node.ref }
                current = node.parentRef.flatMap { snapshot.nodes[$0] }
            }
            return nil
        }

        var seen = Set<String>()
        var out: [String] = []
        for item in compact.items {
            guard let scroll = item.scroll, scroll.isScrollable else { continue }
            if let topWindow, windowOf(item.ref) != topWindow { continue }
            let id = item.testId.map { "#\($0)" } ?? item.resourceId.map { "@\($0)" } ?? item.ref
            let entry = "\(id) \(scroll.describe())"
            if seen.insert(entry).inserted { out.append(entry) }
        }
        return out
    }

    /// The canonical string a quiescence digest hashes: what counts as "the screen
    /// changed".
    ///
    /// Built from the compact view rather than the raw snapshot because the raw tree
    /// carries per-capture noise, and `capturedAtMillis` alone would make every poll
    /// look like a change. Keyboard and focus are folded in because a keyboard
    /// sliding up is a change an agent cares about even when no node moved.
    public static func digestInput(_ compact: CompactObservation) -> String {
        var sb = ""
        sb.reserveCapacity(compact.items.count * 48)
        for item in compact.items {
            let frame = item.frame.map {
                "\(Int($0.x)),\(Int($0.y)),\(Int($0.width))x\(Int($0.height))"
            } ?? ""
            sb += "\(item.ref)|\(item.role)|\(item.label ?? "")|\(frame)|\(item.isEnabled)|\(item.occludedBy ?? "")\n"
        }
        if let kb = compact.screen.keyboard {
            let frame = kb.frame.map { "\(Int($0.y))x\(Int($0.height))" } ?? ""
            sb += "kb:\(kb.visible)|\(frame)\n"
        }
        sb += "focus:\(compact.screen.windowFocused.map { String($0) } ?? "?")"
        return sb
    }

    /// Digest of `digestInput`. The hash itself is only ever compared against
    /// another digest from the SAME process, so the two platforms need the same
    /// inputs but not the same hash function.
    public static func digestOf(_ compact: CompactObservation) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in digestInput(compact).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    /// Is the stated predicate satisfied by THIS probe? Pure, no time involved.
    public func satisfies(_ predicate: WaitPredicate) -> Bool {
        switch predicate.kind {
        // `idle` is decided by quiescence across polls, never by one probe.
        case .idle: return false
        case .appear: return resolved
        case .gone: return !resolved
        case .text:
            guard resolved, let needle = predicate.textContains else { return false }
            return observedText?.contains(needle) == true
        }
    }
}

/// The three-state answer. Never a claim about whether the app is CORRECT.
public enum WaitOutcome: String, Codable, Sendable, CaseIterable {
    /// The predicate held. A fact.
    case resolved
    /// The predicate did not hold, and nothing prevented seeing it.
    case absent
    /// The predicate did not hold, but the screen was in a state where it could
    /// not have been observed. NOT a negative — switch tactics, conclude nothing.
    case unknowable
}

/// The verdict plus its justification.
public struct WaitVerdict: Codable, Sendable {
    public var outcome: WaitOutcome
    /// Explains an `unknowable`. Empty on a trustworthy `absent`.
    public var reasons: [String]
    /// Facts that do not change the outcome but must not be ignored.
    public var caveats: [String]

    public init(outcome: WaitOutcome, reasons: [String] = [], caveats: [String] = []) {
        self.outcome = outcome
        self.reasons = reasons
        self.caveats = caveats
    }

    public static let reasonTreeStillChanging = "tree-still-changing"
    public static let reasonWindowUnfocused = "window-unfocused"
    public static let reasonDomUnavailable = "dom:unavailable"
    public static let reasonDomUnsupportedKernel = "dom:unsupported-kernel"
    /// A `--label` predicate matched several nodes. The resolver refuses to guess,
    /// so the wait cannot answer either — ambiguous is unknowable, not absent.
    public static let reasonSelectorAmbiguous = "selector-ambiguous"
    public static let caveatOccludedPrefix = "occluded-by:"
    public static let caveatMayBeUnbound = "may-be-unbound-not-removed"
    /// The selector resolves, so the next `act` can target it — but it is not
    /// visible. Targetability and visibility are different facts.
    public static let caveatResolvedNotVisible = "resolved-but-not-visible"

    /// Decide the outcome from the last probe plus whether the screen ever settled.
    /// `quiet` is the caller's quiescence finding: two consecutive probes with an
    /// equal digest within the budget.
    public static func classify(_ predicate: WaitPredicate, _ probe: WaitProbe, quiet: Bool) -> WaitVerdict {
        if predicate.kind == .idle {
            // Nobody stated an expectation about content, so there is no negative
            // to report: either it settled, or it never did.
            return quiet
                ? WaitVerdict(outcome: .resolved, caveats: focusCaveats(probe))
                : WaitVerdict(outcome: .unknowable, reasons: [reasonTreeStillChanging])
        }

        if probe.satisfies(predicate) {
            var caveats: [String] = []
            // Targetability is satisfied; being visible and being un-covered are
            // separate questions, and this is the only place they get said.
            // Neither downgrades a `resolved` — that would conflate "can the next
            // act target it" with "can the user see it".
            if predicate.kind != .gone {
                if !probe.visible { caveats.append(caveatResolvedNotVisible) }
                if let occluder = probe.occludedBy { caveats.append("\(caveatOccludedPrefix)\(occluder)") }
            } else if !probe.scrollTravel.isEmpty {
                // A `gone` that came true on a scrollable screen is ambiguous: a
                // recycling list unbinds rows that are merely off-screen.
                caveats.append(caveatMayBeUnbound)
                caveats.append(contentsOf: probe.scrollTravel)
            }
            caveats.append(contentsOf: focusCaveats(probe))
            return WaitVerdict(outcome: .resolved, caveats: caveats)
        }

        var reasons: [String] = []
        // Never settled: the budget ran out mid-animation/mid-load, so "not there"
        // was never established in the first place.
        if !quiet { reasons.append(reasonTreeStillChanging) }
        // The resolver refused to guess between several matches.
        if probe.ambiguous { reasons.append(reasonSelectorAmbiguous) }
        // Another process owns the screen.
        if probe.windowFocused == false { reasons.append(reasonWindowUnfocused) }
        if predicate.selector?.cssSelector != nil {
            // A CSS predicate can only ever be answered by a readable DOM.
            if probe.domUnavailable { reasons.append(reasonDomUnavailable) }
            if probe.domKernelUnsupported { reasons.append(reasonDomUnsupportedKernel) }
        }
        // A row a recycling/lazy list has not bound has no node at all, so its
        // absence is not evidence. Gated on never having RESOLVED a node to read:
        // a `text` miss where the node resolved is a real reading of a real node,
        // and no scrolling changes the text it holds.
        if predicate.kind != .gone && !probe.resolved && !probe.scrollTravel.isEmpty {
            reasons.append(contentsOf: probe.scrollTravel)
        }

        return reasons.isEmpty
            ? WaitVerdict(outcome: .absent)
            : WaitVerdict(outcome: .unknowable, reasons: reasons)
    }

    /// Lost focus is a caveat even on success: the predicate held in this app's
    /// tree, but another process's window is on top of it.
    private static func focusCaveats(_ probe: WaitProbe) -> [String] {
        probe.windowFocused == false ? [reasonWindowUnfocused] : []
    }
}

/// The poll schedule.
///
/// Backoff, because a wait's budget is an order of magnitude larger than
/// `--verify`'s: every poll is a full in-process tree walk plus a transport round
/// trip, so a flat 150ms over 30s would be ~200 tree walks. Dense early (most
/// waits resolve in the first second), sparse later.
public enum WaitSchedule {
    public static let defaultTimeoutMs: Int = 10_000
    public static let defaultQuietMs: Int = 400

    /// Delay before the next poll, given how long we have already waited.
    public static func delayMs(elapsedMs: Int) -> Int {
        if elapsedMs < 2_000 { return 100 }
        if elapsedMs < 5_000 { return 250 }
        return 500
    }
}
