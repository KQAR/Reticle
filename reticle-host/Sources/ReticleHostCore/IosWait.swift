import Foundation
import ReticleProtocol

// `Selector` is spelled out in full throughout this file: the bare name is
// ambiguous against Foundation's ObjC selector type, and a file-private alias
// cannot appear in the signature of an internal, testable helper.

/// Interpret a CLI / batch-step boolean (`true`, `"true"`, `1`) as a flag.
private func waitFlag(_ value: Any?) -> Bool {
    switch value {
    case let b as Bool: return b
    case let s as String: return s == "true" || s == "1"
    case let n as NSNumber: return n.boolValue
    default: return false
    }
}

/// `act wait` on iOS: poll the live tree until a stated predicate holds, then
/// report the same three-state answer the Android helper reports.
///
/// Structured as a runner over an injected `fetch` closure so the loop is testable
/// without a simulator, and so the only iOS-specific parts are the two things that
/// genuinely differ: how a snapshot is fetched, and which resolver decides that a
/// selector resolved. The classification and the screen-level probe come from
/// `ReticleProtocol` — the same code path the Kotlin helper uses, pinned to one
/// fixture table.
///
/// Needs no HID surface: it only observes. So it works on real devices, like
/// `hide-keyboard` and unlike `tap`.
struct IosWaitRunner {
    let fetch: () throws -> Snapshot
    /// Injectable clock, in milliseconds since an arbitrary origin.
    var now: () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }
    var sleep: (Int) -> Void = { ms in Thread.sleep(forTimeInterval: Double(ms) / 1000.0) }

    func run(predicate: WaitPredicate, timeoutMs: Int, quietMs: Int) throws -> [String: Any] {
        let started = now()
        let deadline = started + timeoutMs
        var polls = 0
        var treeChanges = 0
        var lastDigest: String?
        var lastChangeAt = started
        var probe = try probeOnce(predicate)

        while true {
            polls += 1
            if let previous = lastDigest, probe.digest != previous {
                treeChanges += 1
                lastChangeAt = now()
            }
            lastDigest = probe.digest

            let quiet = polls >= 2 && (now() - lastChangeAt) >= quietMs
            // An idle wait is DONE the moment the screen goes quiet — it must not
            // burn the rest of the budget once its whole predicate is satisfied.
            let satisfied = predicate.kind == .idle ? quiet : probe.satisfies(predicate)
            if satisfied || now() >= deadline {
                let verdict = WaitVerdict.classify(predicate, probe, quiet: quiet)
                return IosWaitRunner.render(
                    predicate: predicate,
                    verdict: verdict,
                    probe: probe,
                    elapsedMs: now() - started,
                    timeoutMs: timeoutMs,
                    polls: polls,
                    treeChanges: treeChanges,
                    sinceLastChangeMs: now() - lastChangeAt
                )
            }

            let delay = WaitSchedule.delayMs(elapsedMs: now() - started)
            // Never sleep past the deadline: a 500ms backoff with 80ms of budget
            // left would report a timeout later than the caller asked for.
            sleep(min(delay, max(1, deadline - now())))
            probe = try probeOnce(predicate)
        }
    }

    /// One poll: capture, resolve the way `act` resolves on iOS, read the markers.
    private func probeOnce(_ predicate: WaitPredicate) throws -> WaitProbe {
        let snapshot = try fetch()
        let compact = CompactObservation.from(snapshot)
        // Screen-level half comes from ReticleProtocol, shared with the Android helper.
        let base = WaitProbe.screenState(snapshot, compact)
        guard let selector = predicate.selector else { return base }

        // `Render.labelMatch` is the ambiguity-refusing resolver; ambiguity is
        // CARRIED, not thrown, so a label that turns ambiguous mid-wait ends the
        // wait with an explanation instead of an exception from inside the loop.
        if let label = selector.label {
            do {
                _ = try Render.labelMatch(snapshot, label)
            } catch {
                return withAmbiguous(base)
            }
        }
        // The same lookup `resolveTapPoint` performs, minus its throw. A node
        // without a frame is not targetable, so it does not count as resolved.
        guard let node = Render.findNode(snapshot, selector), node.frame != nil else {
            return base
        }
        let item = compact.items.first { $0.ref == node.ref }
        var probe = base
        probe.resolved = true
        probe.source = item != nil ? "ios:node" : "ios:node(hidden)"
        probe.ref = node.ref
        probe.visible = node.isVisible
        probe.observedText = node.text ?? node.contentDescription
        probe.occludedBy = item?.occludedBy
        return probe
    }

    private func withAmbiguous(_ base: WaitProbe) -> WaitProbe {
        var probe = base
        probe.ambiguous = true
        return probe
    }

    /// Assemble the wire result. Kept static and internal so a test can assert the
    /// exact key set the CLI printer and `--json` consumers read.
    static func render(
        predicate: WaitPredicate,
        verdict: WaitVerdict,
        probe: WaitProbe,
        elapsedMs: Int,
        timeoutMs: Int,
        polls: Int,
        treeChanges: Int,
        sinceLastChangeMs: Int
    ) -> [String: Any] {
        var out: [String: Any] = [
            "gesture": "wait",
            "predicate": predicate.describe(),
            "outcome": verdict.outcome.rawValue,
            "elapsedMs": elapsedMs,
            "timeoutMs": timeoutMs,
            "polls": polls,
            "treeChanges": treeChanges,
            "sinceLastChangeMs": sinceLastChangeMs,
        ]
        if !verdict.reasons.isEmpty { out["reasons"] = verdict.reasons }
        if !verdict.caveats.isEmpty { out["caveats"] = verdict.caveats }
        if let source = probe.source { out["source"] = source }
        if let ref = probe.ref { out["ref"] = ref }
        if let text = probe.observedText { out["observedText"] = text }
        let next = nextSteps(predicate: predicate, verdict: verdict)
        if !next.isEmpty { out["next"] = next }
        return out
    }

    /// Concrete follow-ups, so an `unknowable` hands back a tactic instead of just a
    /// complaint. Mirrors the Kotlin helper's list.
    static func nextSteps(predicate: WaitPredicate, verdict: WaitVerdict) -> [String] {
        var out: [String] = []
        func add(_ step: String) { if !out.contains(step) { out.append(step) } }
        let selector: String? = {
            guard let s = predicate.selector else { return nil }
            if let v = s.testId { return "--test-id \(v)" }
            if let v = s.resourceId { return "--resource-id \(v)" }
            if let v = s.cssSelector { return "--css '\(v)'" }
            if let v = s.ref { return "--ref \(v)" }
            if let v = s.label { return "--label '\(v)'" }
            return nil
        }()
        let marks = verdict.reasons + verdict.caveats
        // Order matters: the most specific blocker first. A caller (usually an agent)
        // acts on the first line, so a generic "try scrolling" must never outrank
        // "the DOM is unreadable right now".
        if marks.contains(where: { $0 == CompactObservation.occluderKeyboard || $0.hasSuffix(":keyboard") }) {
            add("act hide-keyboard")
        }
        if marks.contains(WaitVerdict.reasonWindowUnfocused) {
            // No command can dismiss another process's window from in here.
            add("resolve the foreground system window first (it is in no node of this tree)")
        }
        if marks.contains(WaitVerdict.reasonDomUnavailable) {
            add("dismiss the blocking JS modal, then re-run this wait")
        }
        if marks.contains(WaitVerdict.reasonDomUnsupportedKernel) {
            add("target it as a plain view (--test-id / --point); --css can never match this kernel")
        }
        if marks.contains(WaitVerdict.reasonSelectorAmbiguous) {
            add("narrow the selector (--test-id / --resource-id / --ref)")
        }
        // Scrolling can only ever produce a NATIVE node; a DOM element is not
        // brought into being by dragging a native container.
        if marks.contains(where: { $0.contains("scroll:") }), let selector,
           predicate.selector?.cssSelector == nil {
            add("act scroll-to \(selector)")
        }
        if marks.contains(WaitVerdict.reasonTreeStillChanging) {
            add("raise --timeout, or wait for the screen to settle first (act wait --idle)")
        }
        if verdict.outcome == .absent {
            add("ui compact --live to see what IS on screen")
        }
        return out
    }

    /// Build the predicate the caller stated. Mirrors `HelperWait.predicateFrom`,
    /// including every refusal, so the two platforms reject the same inputs.
    static func predicate(from params: [String: Any]) throws -> WaitPredicate {
        let token = params["for"] as? String
        var selector: ReticleProtocol.Selector?
        if let token, token != "idle" {
            selector = try parseWaitToken(token)
        } else {
            let s = selectorFromWaitParams(params)
            if s.testId != nil || s.resourceId != nil || s.cssSelector != nil
                || s.ref != nil || s.label != nil {
                selector = s
            }
        }
        let gone = waitFlag(params["gone"])
        let textContains = params["textContains"] as? String
        let idleRequested = waitFlag(params["idle"]) || token == "idle"

        if idleRequested {
            if selector != nil {
                throw HelperError(
                    "wait --idle waits for the SCREEN to stop changing, so it takes no selector. "
                        + "Drop the selector, or drop --idle to wait for that selector instead."
                )
            }
            if gone || textContains != nil {
                throw HelperError("wait --idle takes neither --gone nor --text")
            }
            return WaitPredicate(kind: .idle)
        }
        // These two are checked BEFORE the missing-predicate error, so a caller who
        // passed something unusable gets told why it is unusable rather than the
        // generic "needs a predicate". Same order as the Kotlin helper.
        if params["point"] != nil {
            throw HelperError(
                "wait cannot take --point: a raw coordinate always 'resolves', so there is nothing to wait for"
            )
        }
        if params["alias"] != nil {
            throw HelperError(
                "wait cannot take --alias: an outline alias describes the screen it was captured on, "
                    + "which is the screen a wait expects to change. Use --test-id / --resource-id / --css / --ref."
            )
        }
        guard let selector else {
            throw HelperError(
                "wait needs a predicate: --for '#testId' (or --test-id / --resource-id / --css / --ref / --label), "
                    + "optionally with --gone or --text <substring>; or --idle to wait for the screen to settle"
            )
        }
        if gone && textContains != nil {
            throw HelperError("wait takes --gone or --text, not both")
        }
        if gone { return WaitPredicate(kind: .gone, selector: selector) }
        if let textContains { return WaitPredicate(kind: .text, selector: selector, textContains: textContains) }
        return WaitPredicate(kind: .appear, selector: selector)
    }

    /// `--for`'s token grammar, identical to `--verify`'s so there is only one
    /// spelling to learn.
    static func parseWaitToken(_ token: String) throws -> ReticleProtocol.Selector {
        if token.hasPrefix("#") { return ReticleProtocol.Selector(testId: String(token.dropFirst())) }
        if token.hasPrefix("@") { return ReticleProtocol.Selector(resourceId: String(token.dropFirst())) }
        if token.hasPrefix("css=") { return ReticleProtocol.Selector(cssSelector: String(token.dropFirst(4))) }
        if token.hasPrefix("testId=") { return ReticleProtocol.Selector(testId: String(token.dropFirst(7))) }
        if token.hasPrefix("resourceId=") { return ReticleProtocol.Selector(resourceId: String(token.dropFirst(11))) }
        if token.hasPrefix("ref=") { return ReticleProtocol.Selector(ref: String(token.dropFirst(4))) }
        if token.hasPrefix("label=") { return ReticleProtocol.Selector(label: String(token.dropFirst(6))) }
        if token.contains("=") {
            throw HelperError(
                "unrecognized --for selector '\(token)': use #<testId>, testId=<id>, @<resourceId>, "
                    + "resourceId=<id>, css=<selector>, label=<text>, ref=<ref>, or a bare ref"
            )
        }
        return ReticleProtocol.Selector(ref: token)
    }

    private static func selectorFromWaitParams(_ params: [String: Any]) -> ReticleProtocol.Selector {
        ReticleProtocol.Selector(
            testId: params["testId"] as? String,
            resourceId: params["resourceId"] as? String,
            cssSelector: (params["css"] as? String) ?? (params["cssSelector"] as? String),
            ref: params["ref"] as? String,
            label: params["label"] as? String
        )
    }
}
