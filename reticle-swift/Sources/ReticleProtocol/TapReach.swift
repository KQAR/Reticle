import Foundation

/// Where a tap on a node can actually land: the part of its frame that is still
/// on screen and not cut away by a clipping ancestor.
///
/// Twin of the Kotlin `TapReach`, where the two measurements behind it are
/// written down — a row laid out below the bottom of the display whose tap was
/// dispatched at `y=2468` on a 2412px screen, and a row scrolled under a sheet's
/// sticky header whose full unclipped rect sent the touch to the page behind.
/// Both reported `settled=1`.
///
/// Pinned for both ports by reticle-protocol/fixtures/tap-reach.cases.json.
public enum TapReach {

    /// Why a tap cannot reach a target at all.
    public static let unreachableOffScreen = "off-screen"
    public static let unreachableClipped = "clipped"

    /// The tap point for a ref, plus what had to be taken into account.
    public struct Reach: Equatable, Sendable {
        /// Nil when the node is unreachable; `reason` then says which way.
        public var point: Point?
        /// The reachable rect, or nil when there is none.
        public var rect: Rect?
        /// True when `point` is NOT the frame's own centre.
        public var adjusted: Bool
        /// `off-screen` / `clipped`, or nil when the target is reachable.
        public var reason: String?
        /// The clipping ancestor, when the frame was cut by one.
        public var by: String?

        public init(
            point: Point?, rect: Rect?, adjusted: Bool, reason: String? = nil, by: String? = nil
        ) {
            self.point = point
            self.rect = rect
            self.adjusted = adjusted
            self.reason = reason
            self.by = by
        }

        /// The sentence a caller gets, ending in the command that fixes it.
        public func explain(_ ref: String) -> String {
            switch reason {
            case TapReach.unreachableOffScreen:
                return "\(ref) is laid out off screen, so a tap at its centre lands outside the "
                    + "display — bring it into view first with `act scroll-to`"
            case TapReach.unreachableClipped:
                return "\(ref) is fully clipped by \(by ?? "an ancestor"), so no part of it can "
                    + "receive a touch — scroll it into its container's viewport with `act scroll-to`"
            default:
                return "\(ref) is only partly visible" + (by.map { " (clipped by \($0))" } ?? "")
                    + ", so the tap aims at the visible part rather than at the frame's centre"
            }
        }
    }

    /// Does this node clip what is drawn inside it? Deliberately narrow — see the
    /// Kotlin twin: a false positive MOVES a tap that was landing correctly.
    private static func clips(_ node: Node, screen: Rect) -> Bool {
        if node.scroll != nil { return true }
        // A full-screen window and the screen are the same cut — see the Kotlin twin.
        if node.kind == .window {
            guard let frame = node.frame else { return false }
            return frame.width < screen.width || frame.height < screen.height
        }
        for key in ["domStyleOverflowX", "domStyleOverflowY"] {
            if case .text(let value)? = node.custom[key], value != "visible" { return true }
        }
        return false
    }

    private static func intersect(_ a: Rect, _ b: Rect) -> Rect? {
        let left = max(a.x, b.x)
        let top = max(a.y, b.y)
        let right = min(a.x + a.width, b.x + b.width)
        let bottom = min(a.y + a.height, b.y + b.height)
        if right <= left || bottom <= top { return nil }
        return Rect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Where a tap on `ref` can land in `snapshot`.
    public static func of(_ snapshot: Snapshot, ref: String) -> Reach? {
        guard let node = snapshot.nodes[ref], let frame = node.frame else { return nil }
        let screen = Rect(
            x: 0, y: 0, width: snapshot.screen.size.width, height: snapshot.screen.size.height
        )
        // Screen first, and on the RAW frame — see the Kotlin twin.
        if intersect(frame, screen) == nil {
            return Reach(point: nil, rect: nil, adjusted: true, reason: unreachableOffScreen)
        }
        var rect: Rect? = frame
        var clipper: String?
        var current = node.parentRef.flatMap { snapshot.nodes[$0] }
        var seen = Set<String>()
        while let ancestor = current, !seen.contains(ancestor.ref) {
            seen.insert(ancestor.ref)
            if let bounds = ancestor.frame, clips(ancestor, screen: screen) {
                let next = rect.flatMap { intersect($0, bounds) }
                if next != rect { clipper = ancestor.ref }
                rect = next
                if rect == nil { break }
            }
            current = ancestor.parentRef.flatMap { snapshot.nodes[$0] }
        }
        guard let clipped = rect else {
            return Reach(point: nil, rect: nil, adjusted: true, reason: unreachableClipped, by: clipper)
        }
        guard let onScreen = intersect(clipped, screen) else {
            return Reach(point: nil, rect: nil, adjusted: true, reason: unreachableOffScreen, by: clipper)
        }
        let adjusted = onScreen != frame
        return Reach(
            point: Point(x: onScreen.centerX, y: onScreen.centerY),
            rect: onScreen,
            adjusted: adjusted,
            by: adjusted ? clipper : nil
        )
    }
}
