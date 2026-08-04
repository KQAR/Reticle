import Foundation

/// Is a DOM node's rect consistent with the web view that draws it?
///
/// Twin of the Kotlin `DomRectCheck`, where the measurement is written down: on one
/// page of a real hybrid flow the DOM rects were offset from what was on screen by
/// roughly 130px, a css tap missed twice reporting `settled=1`, and only a
/// screenshot revealed it.
///
/// Only the STRONG case is reported — a rect whose centre falls outside the view
/// that draws it, which is impossible for a correctly-folded rect. A small offset
/// has no second source to be compared against, and a warning that fires on
/// ordinary screens is one nobody reads.
public enum DomRectCheck {

    /// The wire/warning token for a rect folded outside its own web view.
    public static let outsideHostReason = "dom-rect-outside-host"

    /// The complaint about `ref`, or nil when there is nothing to say.
    public static func outsideHost(_ snapshot: Snapshot, ref: String) -> String? {
        guard let node = snapshot.nodes[ref], node.kind == .domNode, let frame = node.frame,
            let host = hostView(snapshot, node), let hostFrame = host.frame,
            hostFrame.width > 0, hostFrame.height > 0
        else { return nil }
        let cx = frame.centerX
        let cy = frame.centerY
        let inside =
            cx >= hostFrame.x && cx <= hostFrame.x + hostFrame.width && cy >= hostFrame.y
            && cy <= hostFrame.y + hostFrame.height
        if inside { return nil }
        return "\(ref)'s DOM rect is folded to a point OUTSIDE the web view that draws it "
            + "(\(host.testId ?? host.ref) at [\(Int(hostFrame.x)),\(Int(hostFrame.y)) "
            + "\(Int(hostFrame.width))x\(Int(hostFrame.height))]), so the page-to-device fold for "
            + "this node is wrong and a tap at its centre cannot land on it — re-capture "
            + "(`ui report`) and, if it persists, target the element by `act activate --css`, which "
            + "needs no coordinates"
    }

    /// The nearest non-DOM ancestor: the view hosting this document.
    private static func hostView(_ snapshot: Snapshot, _ node: Node) -> Node? {
        var current = node.parentRef.flatMap { snapshot.nodes[$0] }
        var seen = Set<String>()
        while let candidate = current, seen.insert(candidate.ref).inserted {
            if candidate.kind != .domNode { return candidate }
            current = candidate.parentRef.flatMap { snapshot.nodes[$0] }
        }
        return nil
    }
}
