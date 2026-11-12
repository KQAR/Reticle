import Foundation
import ReticleHostShared
import ReticleProtocol

/// A tap's aim and the evidence it carries, judged in the host for any platform
/// that can hand over snapshots: where it resolved, whether that point had stopped
/// moving, and what the tree it was dispatched against says about it.
///
/// Android's tap runs on this end to end (the helper only captures and dispatches);
/// iOS shares the pure evidence half. The input itself is the caller's.
public enum ActTap {
    /// Where a tap will go, and the snapshot that decision was made on.
    public struct Aim {
        /// The target as last resolved — after the settle loop, when one ran.
        public let target: SelectorResolution.Resolved
        /// The first resolution's point, so a confirm that moved it can say so.
        public let first: Point
        /// nil when no confirm ran (a raw point, `--no-settle`).
        public let stable: Bool?
        /// The capture `target` was resolved in. Its refs are `target.ref`'s.
        public let snapshot: Snapshot
    }

    /// Re-resolve budget for the default confirm: it bounds the animating case, not
    /// the common one, which ends on the first agreeing re-read.
    public static let confirmBudgetMs = 800
    /// Budget for an explicit `--settle`, for a target known to be sliding in.
    public static let settleBudgetMs = 2_000
    public static let pollMs = 150

    /// Resolve `first`, then — unless the caller typed a coordinate or opted out —
    /// re-resolve until the point holds still.
    ///
    /// Why the confirm is the default rather than `--settle`'s alone: resolution and
    /// dispatch are two steps, and the screen can move between them for reasons the
    /// caller has no cue for — a keyboard an earlier `type` raised, a scroll. Measured
    /// on a device: a form row resolved to a rect already 161px stale and the touch
    /// opened the sheet of the row below, reported as a plain success.
    public static func aim(
        _ params: [String: Any],
        first: Snapshot,
        resolve: (Snapshot) throws -> SelectorResolution.Resolved,
        fetch: SnapshotFetch
    ) async throws -> Aim {
        let rawPoint = params["point"] != nil
        let settle = ActParams.isTruthy(params["settle"])
        if settle, rawPoint {
            throw HelperError("--settle needs a selector: a raw --point has nothing to re-resolve, "
                + "so there is no way to tell whether it has stopped moving")
        }
        let target = try resolve(first)
        if rawPoint || ActParams.isTruthy(params["noSettle"]) {
            return Aim(target: target, first: target.point, stable: nil, snapshot: first)
        }
        let budget = intParam(params["settleTimeoutMs"]) ?? (settle ? settleBudgetMs : confirmBudgetMs)
        return await confirm(target, in: first, budgetMs: budget, resolve: resolve, fetch: fetch)
    }

    /// The settle loop: same point twice in a row, or the budget lapses. Never
    /// refuses to tap — a lapsed budget returns the freshest aim flagged unstable,
    /// and a target that vanished mid-settle (a menu dismissed under us) returns the
    /// last good one, for the dispatch or the caller's own verification to judge.
    public static func confirm(
        _ first: SelectorResolution.Resolved,
        in snapshot: Snapshot,
        budgetMs: Int,
        sleep: (Int) async -> Void = { try? await Task.sleep(for: .milliseconds($0)) },
        resolve: (Snapshot) throws -> SelectorResolution.Resolved,
        fetch: SnapshotFetch
    ) async -> Aim {
        let deadline = Date().addingTimeInterval(Double(budgetMs) / 1000)
        var previous = first
        var previousSnapshot = snapshot
        while Date() < deadline {
            await sleep(pollMs)
            guard let current = try? await fetch(), let resolved = try? resolve(current) else {
                return Aim(target: previous, first: first.point, stable: false, snapshot: previousSnapshot)
            }
            if abs(resolved.point.x - previous.point.x) < 1, abs(resolved.point.y - previous.point.y) < 1 {
                return Aim(target: resolved, first: first.point, stable: true, snapshot: current)
            }
            previous = resolved
            previousSnapshot = current
        }
        return Aim(target: previous, first: first.point, stable: false, snapshot: previousSnapshot)
    }

    /// Every fact a tap reports that is judged from the tree it was dispatched
    /// against, BEFORE the touch: after it, the screen this point was aimed at may
    /// not exist any more. `bool` builds the boolean values, so a platform can keep
    /// the printed form its callers already parse.
    public static func evidence(
        _ aim: Aim, rawPoint: Bool, bool: (Bool) -> Any = { $0 }
    ) -> [String: Any] {
        let point = aim.target.point
        let snapshot = aim.snapshot
        var out: [String: Any] = ["source": aim.target.source]
        if let ref = aim.target.ref { out["ref"] = ref }
        // Only part of the frame was reachable, so the tap aimed at the visible part
        // rather than at a centre outside it; the coordinate no longer matches the
        // rect the caller reads in the tree, and this is why.
        if let reach = aim.target.reachNote { out["reach"] = reach }
        // false = still moving when the budget lapsed: the point may already be stale.
        if let stable = aim.stable { out["settled"] = bool(stable) }
        // The evidence that the first read WAS stale. Without it the confirm would
        // silently fix the tap and the caller never learns the screen moved.
        let dx = Int(point.x - aim.first.x), dy = Int(point.y - aim.first.y)
        if dx != 0 || dy != 0 { out["rectMoved"] = "\(dx),\(dy)" }
        // A coordinate says why it had to be one: a selector was available here, or
        // a named boundary made pixels the only path.
        if rawPoint { out["coverage"] = ScreenCoverage.at(snapshot, x: point.x, y: point.y).jsonObject }
        // Who receives the touch instead of the target — a selector tap needs this
        // too: it resolves correctly and is then eaten by the IME or a window above.
        if let obstruction = ScreenCoverage.obstruction(snapshot, x: point.x, y: point.y, targetRef: aim.target.ref) {
            out["obstruction"] = obstruction.jsonObject(x: point.x, y: point.y)
        }
        if let ref = aim.target.ref {
            // A DOM rect folded to a point outside the web view that draws it:
            // impossible for a correct fold, and silent otherwise (`settled=1`).
            if let complaint = DomRectCheck.outsideHost(snapshot, ref: ref) { out["rectSuspect"] = complaint }
            if let inert = inertNote(snapshot, ref: ref) { out["targetInert"] = inert }
        }
        return out
    }

    /// A note when the resolved node publishes no control of its own — a caption, a
    /// wrapper, a plain row. Not a refusal: a framework-built field binds its handler
    /// in JS and publishes no role, tabindex or `aria-*`, so a `--label` tap on its
    /// caption really is how it is driven (measured on a real form: five such rows,
    /// each one coordinate-driven until this). But "I tapped a control" and "I tapped
    /// a caption and relied on the app's handler" are different claims.
    public static func inertNote(_ snapshot: Snapshot, ref: String) -> String? {
        guard let node = snapshot.nodes[ref], !node.isInteractive else { return nil }
        let what = node.role ?? node.typeName
        return "the resolved node (\(ref), \(what)) publishes no control of its own — the touch was "
            + "dispatched at its centre and only the app's own handler can act on it, so treat this "
            + "as a coordinate-grade tap and verify the effect"
    }

    private static func intParam(_ value: Any?) -> Int? {
        switch value {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s)
        default: return nil
        }
    }
}
