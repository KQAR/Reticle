import Foundation
import ReticleHostShared
import ReticleProtocol

/// Where an action is aimed, and whether that aim can be trusted: selector
/// resolution through the SHARED resolver, reach adjustment, the settle loop, and
/// the page's own record of where a DOM tap landed.
///
/// These belong together because they are the answers a gesture needs BEFORE it
/// dispatches and the evidence it needs after — none of them synthesize input.
/// The platform supplies only `fetch`.
public enum ActTargeting {
    /// A point plus whether its position was confirmed to have stopped moving.
    /// Shared by the tap path and `scroll-to`, which settle for the same reason.
    public struct SettledPoint {
        public let point: Point
        public let stable: Bool

        public init(point: Point, stable: Bool) {
            self.point = point
            self.stable = stable
        }
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
    public static func resolveTapPoint(_ params: [String: Any], snapshot: Snapshot) throws -> Point {
        try resolveTarget(params, snapshot: snapshot).point
    }

    /// Ask the PAGE where the touch went, for a tap that resolved to a DOM node.
    ///
    /// The one answer a tap has that is not Reticle's own arithmetic: if the
    /// page-to-device fold is wrong, the selector, the settle and the dispatch all
    /// stay true while the touch lands elsewhere (measured ~130px on a real page).
    /// Costs one snapshot and only on a DOM tap — a `--css` hit, or any selector
    /// whose node in `dispatched` is a DOM node (a `--label` that matched page text).
    /// Silent whenever it cannot judge — a selector that no longer resolves (the tap
    /// navigated), an unreadable page, a sealed frame — because a check that could
    /// not run is not evidence. See `DomTapWitness`.
    public static func domTapLanding(
        _ params: [String: Any], target: SelectorResolution.Resolved, dispatched: Snapshot?,
        fetch: SnapshotFetch
    ) async -> String? {
        let isDom = target.source.hasPrefix("dom")
            || target.ref.flatMap { dispatched?.nodes[$0] }?.kind == .domNode
        guard isDom else { return nil }
        // Let the page's own handler run before asking it what it received.
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let after = try? await fetch(),
            let resolved = ((try? SelectorResolution.resolve(
                snapshot: after,
                semantic: SemanticTree.build(from: after),
                selector: ActParams.selector(params)
            )) ?? nil),
            let ref = resolved.ref
        else { return nil }
        return DomTapWitness.describe(after, intendedRef: ref)
    }

    public static func resolveTarget(
        _ params: [String: Any], snapshot: Snapshot
    ) throws -> SelectorResolution.Resolved {
        if let p = ActParams.point(params["point"]) {
            return SelectorResolution.Resolved(point: p, source: "point", ref: nil)
        }
        let selector = ActParams.selector(params)
        guard let resolved = try SelectorResolution.resolve(
            snapshot: snapshot,
            semantic: SemanticTree.build(from: snapshot),
            selector: selector
        ) else {
            // One explanation of a miss for both platforms — see `SelectorDiagnostics`.
            throw HelperError(SelectorDiagnostics.pointMiss(snapshot, selector))
        }
        return try withReach(snapshot, resolved)
    }

    /// Aim at the part of the target a touch can actually reach, or refuse.
    ///
    /// The Android helper's twin (`withReach` in HelperRuntime.kt): a frame is a
    /// LAYOUT box, and half of it can be below the display or scrolled under a
    /// sticky header while the tree still reports the whole rect. Refusing is right
    /// for a resolved SELECTOR — the tool computed the point and `act scroll-to`
    /// fixes it — while a coordinate the caller typed is left alone.
    public static func withReach(
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

    public static func settleRequested(_ params: [String: Any]) -> Bool { ActParams.isTruthy(params["settle"]) }

    /// Re-resolve the tap target until it lands on the same point twice in a row —
    /// it has stopped moving — or the budget runs out. The point-only face of
    /// `ActTap.confirm`, for the iOS tap, which aims from its own first capture.
    public static func settleTapPoint(
        _ params: [String: Any], first: Point, snapshot: Snapshot, fetch: SnapshotFetch
    ) async -> SettledPoint {
        let fallback = settleRequested(params) ? ActTap.settleBudgetMs : ActTap.confirmBudgetMs
        let aim = await ActTap.confirm(
            SelectorResolution.Resolved(point: first, source: "", ref: nil),
            in: snapshot,
            budgetMs: (params["settleTimeoutMs"] as? Int) ?? fallback,
            resolve: { try resolveTarget(params, snapshot: $0) },
            fetch: fetch
        )
        return SettledPoint(point: aim.target.point, stable: aim.stable ?? false)
    }
}
