import Foundation
import ReticleHostShared
import ReticleProtocol

// Where an action is aimed, and whether that aim can be trusted: snapshot fetch,
// selector resolution through the SHARED resolver, reach adjustment, the settle
// loop, and the two after-the-fact witnesses (the page's own pointer record, and
// the warning for a window this app does not own).
//
// Split out of `IosHelperClient`. These belong together because they are the
// answers a gesture needs BEFORE it dispatches and the evidence it needs after —
// none of them synthesize input, and every one of them is shared by several
// gestures plus `scroll-to` and `wait`.
extension IosHelperClient {
    /// A DOM node's own selector chain, when the ref names one. Typing has to be
    /// routed by what the target IS rather than by which flag named it: a DOM node
    /// has no UIKit responder whatever found it, so a `--ref` that lands on one
    /// takes the same page-level path `--css` does.
    func webChain(forRef ref: String, in snapshot: Snapshot) -> String? {
        guard let node = snapshot.nodes[ref], node.kind == .domNode else { return nil }
        return node.domCssSelector()
    }

    /// The one thing an action can say about a window it cannot see. `windowFocused`
    /// is read from `UIApplication.applicationState`, so false is not a guess about
    /// z-order — it is the system telling the app it is not the one receiving input,
    /// which on a device is the only trace another process's alert leaves.
    func inactiveWarning(_ snapshot: Snapshot?) -> String? {
        guard snapshot?.screen.windowFocused == false else { return nil }
        return "the app was NOT active when this was dispatched — another process's window "
            + "(a system prompt, which is in no tree and in no in-process screenshot) holds input. "
            + "Actions on this app's own content can be inert while still reporting success; "
            + "deal with that prompt first"
    }

    func fetchSnapshot(_ pkg: String) async throws -> Snapshot {
        let (data, _) = try await IosAgentHTTP(bundleId: pkg).get(Endpoints.snapshot)
        return try ReticleJSON.decode(Snapshot.self, from: data).requireSupportedSchema()
    }

    /// Resolves a tap target through the SHARED resolver in `ReticleProtocol`, the
    /// same order the Kotlin helper applies and the same one pinned by
    /// `reticle-protocol/fixtures/selector-resolution.cases.json`.
    ///
    /// This used to be a hand-rolled walk over `Render.findNode` — the view tree
    /// only — so iOS silently skipped the semantic-first rule the architecture
    /// documents, matched region labels case-sensitively where Android did not, and
    /// applied a different selector precedence. The semantic tree is derived here
    /// from the same capture, so both trees still describe one frame.
    func resolveTapPoint(_ params: [String: Any], snapshot: Snapshot) throws -> Point {
        try resolveTarget(params, snapshot: snapshot).point
    }

    /// Ask the PAGE where the touch went, for a tap that resolved to a DOM node.
    ///
    /// Twin of the Android helper's `domTapLanding`. Costs one snapshot and only on a
    /// DOM tap: the witness's record lives in the page, so it can only be read after the
    /// gesture. Silent whenever it cannot judge — a selector that no longer resolves
    /// (the tap navigated), an unreadable page, a sealed frame — because a check that
    /// could not run is not evidence. See `DomTapWitness`.
    func domTapLanding(
        _ pkg: String, _ params: [String: Any], target: SelectorResolution.Resolved
    ) async -> String? {
        guard target.source.hasPrefix("dom") else { return nil }
        // Let the page's own handler run before asking it what it received.
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let after = try? await fetchSnapshot(pkg),
            let resolved = ((try? SelectorResolution.resolve(
                snapshot: after,
                semantic: SemanticTree.build(from: after),
                selector: selectorFromParams(params)
            )) ?? nil),
            let ref = resolved.ref
        else { return nil }
        return DomTapWitness.describe(after, intendedRef: ref)
    }

    func resolveTarget(
        _ params: [String: Any], snapshot: Snapshot
    ) throws -> SelectorResolution.Resolved {
        if let p = parsePoint(params["point"]) {
            return SelectorResolution.Resolved(point: p, source: "point", ref: nil)
        }
        let selector = selectorFromParams(params)
        guard let resolved = try SelectorResolution.resolve(
            snapshot: snapshot,
            semantic: SemanticTree.build(from: snapshot),
            selector: selector
        ) else {
            throw HelperError("could not resolve a tap point from selector \(selector.describe())"
                // The same omission the Android helper's message had: `--label` is
                // what resolves a screen whose only stable handle is the visible
                // string, and a miss that does not name it is how a flow ends up
                // driven by coordinates.
                + (selector.describe() == "<empty>"
                    ? ". No selector was given. Use --label \"<visible text>\" when the on-screen "
                        + "string is the only stable handle, or one of: --test-id, --resource-id, "
                        + "--css, --ref, --alias @N, or --point x,y"
                    : "")
                + Self.refLifetimeNote(snapshot, selector)
                // The recycling/lazy-list note is about a row that was never realized.
                // For a REF miss on a screen with a DOM on it, the cause is
                // renumbering, so that note is a wrong lead rather than a weak one.
                + (selector.ref != nil && snapshot.nodes.values.contains { $0.kind == .domNode }
                    ? "" : Self.scrollHint(snapshot)))
        }
        return try Self.withReach(snapshot, resolved)
    }

    /// What a `--ref` miss actually means — the twin of `SelectorDiagnostics.refMiss`
    /// in the Android helper.
    ///
    /// A ref is a traversal INDEX, valid for the snapshot it came from: any relayout,
    /// or in a WebView any re-render, renumbers the tree. Measured on a WebView-heavy
    /// screen, a ref read out of one report was dead ~1s later and the answer offered
    /// native refs that cannot stand in for a DOM node. `--css` survives a re-render,
    /// so that is what gets named.
    static func refLifetimeNote(_ snapshot: Snapshot, _ selector: ReticleProtocol.Selector) -> String {
        guard let ref = selector.ref else { return "" }
        var note = ". '\(ref)' is not in the current tree: a ref is a traversal INDEX, valid only "
            + "for the snapshot it came from, and any relayout or re-render renumbers the whole tree"
        let domNodes = snapshot.nodes.values.filter { $0.kind == .domNode }
        if domNodes.isEmpty {
            return note + ". Prefer a handle that survives a re-capture: --test-id / --label"
        }
        let candidates = domNodes.filter { $0.isInteractive || $0.role == "textField" }
        let handles = (candidates.isEmpty ? domNodes : candidates)
            .compactMap { $0.domId().map { id in "#\(id)" } ?? $0.domCssSelector() }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .prefix(4)
        note += ". This screen carries \(domNodes.count) DOM node(s), which no native ref can "
            + "substitute for — address one with --css, which survives a re-render"
        if !handles.isEmpty {
            note += ": " + handles.map { "'\($0)'" }.joined(separator: ", ")
        }
        return note
    }

    /// Aim at the part of the target a touch can actually reach, or refuse.
    ///
    /// The Android helper's twin (`withReach` in HelperRuntime.kt): a frame is a
    /// LAYOUT box, and half of it can be below the display or scrolled under a
    /// sticky header while the tree still reports the whole rect. Refusing is right
    /// for a resolved SELECTOR — the tool computed the point and `act scroll-to`
    /// fixes it — while a coordinate the caller typed is left alone.
    static func withReach(
        _ snapshot: Snapshot, _ resolved: SelectorResolution.Resolved
    ) throws -> SelectorResolution.Resolved {
        guard let ref = resolved.ref, let reach = TapReach.of(snapshot, ref: ref) else { return resolved }
        guard let point = reach.point else { throw HelperError(reach.explain(ref)) }
        guard reach.adjusted else { return resolved }
        var adjusted = resolved
        adjusted.point = point
        adjusted.reachNote = reach.explain(ref)
        return adjusted
    }

    func settleRequested(_ params: [String: Any]) -> Bool { isTruthy(params["settle"]) }

    /// Re-resolve the tap target until it lands on the same point twice in a row —
    /// it has stopped moving — or the budget runs out.
    ///
    /// Resolution and dispatch are two steps, and a sheet or menu animating in moves
    /// between them: the captured rect is intermediate, so the synthesized touch can
    /// land on the neighbouring row. This is the same stabilize step `scroll-to`
    /// already performs, on the tap's own resolution path (no `isVisible` proxy).
    /// It never refuses to tap — a lapsed budget returns the freshest point flagged
    /// `stable = false`, which the caller reports as evidence.
    func settleTapPoint(
        _ pkg: String, _ params: [String: Any], first: Point
    ) async -> SettledPoint {
        // Short default budget: on a settled screen the loop returns as soon as one
        // re-resolve agrees, so this bounds the animating case, not the common one.
        // An explicit `--settle` means "this IS animating" and gets the full 2s.
        let fallback = settleRequested(params) ? 2_000 : 800
        let budget = Double((params["settleTimeoutMs"] as? Int) ?? fallback) / 1000.0
        let deadline = Date().addingTimeInterval(budget)
        var previous = first
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(0.15))
            // A target that vanishes mid-settle (a menu dismissed under us) is not a
            // failure of the tap yet: report the freshest point and let the dispatch,
            // or the caller's own verification, be the judge.
            guard let snapshot = try? await fetchSnapshot(pkg),
                  let current = try? resolveTapPoint(params, snapshot: snapshot) else {
                return SettledPoint(point: previous, stable: false)
            }
            if abs(current.x - previous.x) < 1, abs(current.y - previous.y) < 1 {
                return SettledPoint(point: current, stable: true)
            }
            previous = current
        }
        return SettledPoint(point: previous, stable: false)
    }
}
