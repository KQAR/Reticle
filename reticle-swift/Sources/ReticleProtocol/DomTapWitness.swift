import Foundation

/// Did the page receive the touch, and on which element?
///
/// Twin of the Kotlin `DomTapWitness`, where the reasoning is written down. The short
/// version: everything else a tap reports is what it INTENDED (the selector resolved,
/// the rect had stopped moving, the coordinate was dispatched), so a wrong
/// page-to-device fold is silent — it reported `settled=1` and missed by ~130px on a
/// real page (#234). The page's own account of receiving a pointer is the only
/// independent source for where the touch actually went.
///
/// Quiet on every ordinary screen: a touch that lands on the element aimed at, or
/// anywhere inside it, says nothing. Silent rather than guessing whenever the evidence
/// cannot carry a verdict — a non-DOM target, an unreadable page, a target inside a
/// frame the witness cannot live in, or a record too old to belong to this gesture.
///
/// The judgement is pinned for both ports by
/// `reticle-protocol/fixtures/dom-tap-witness.cases.json`.
public enum DomTapWitness {

    /// The touch arrived in the page, on something else.
    public static let landedElsewhere = "dom-tap-landed-elsewhere"

    /// The page never saw a pointer event for this gesture.
    public static let notReceived = "dom-tap-not-received"

    /// How old a witnessed pointer may be and still belong to the tap being reported.
    public static let maxAgeMs: Int64 = 2500

    /// How the element that received the touch relates to the one aimed at.
    public enum Relation: String {
        /// Off-tree: a pointer arrived, no captured element matched it.
        case unknown
        /// A sibling/cousin — the plain miss.
        case other
        /// The touch landed on an element that CONTAINS the one aimed at.
        case ancestor
    }

    /// The structured judgement the fixture pins; nil from `of` means nothing to say.
    public struct Verdict: Equatable {
        public let token: String
        public let landedOn: String?
        public let at: String?
        public let relation: Relation

        public init(token: String, landedOn: String? = nil, at: String? = nil, relation: Relation = .unknown) {
            self.token = token
            self.landedOn = landedOn
            self.at = at
            self.relation = relation
        }
    }

    public static func of(_ after: Snapshot, intendedRef: String) -> Verdict? {
        guard let intended = after.nodes[intendedRef], intended.kind == .domNode,
            let host = hostView(after, intended)
        else { return nil }
        // A capture that could not read this page cannot be asked where a touch went.
        if host.custom["domStatus"] != nil { return nil }
        if insideOpaqueFrame(after, intended) { return nil }
        guard case .integer(let age)? = host.custom["domPointerAgeMs"],
            case .integer(let x)? = host.custom["domPointerX"],
            case .integer(let y)? = host.custom["domPointerY"],
            age <= maxAgeMs
        else { return Verdict(token: notReceived) }
        let at = "\(x),\(y)"
        let hit = after.nodes.values.first { node in
            if case .bool(true)? = node.custom["domPointerHit"] { return true }
            return false
        }
        guard let hit else { return Verdict(token: landedElsewhere, at: at, relation: .unknown) }
        // The element aimed at, or anything inside it: a tap on a button lands on the
        // span that draws its caption, and that is the button being tapped.
        if hit.ref == intended.ref || isDescendant(after, hit, ancestorRef: intended.ref) { return nil }
        let relation: Relation =
            isDescendant(after, intended, ancestorRef: hit.ref) ? .ancestor : .other
        return Verdict(token: landedElsewhere, landedOn: hit.ref, at: at, relation: relation)
    }

    /// The one-line complaint for `of`, or nil when there is nothing to say.
    public static func describe(_ after: Snapshot, intendedRef: String) -> String? {
        guard let verdict = of(after, intendedRef: intendedRef) else { return nil }
        let intended = after.nodes[intendedRef]
        let aimedAt = intended?.domCssSelector().map { "'\($0)'" } ?? intendedRef
        if verdict.token == notReceived {
            return "the page received no pointer event for this tap, so nothing in it was "
                + "touched — the coordinate went somewhere else entirely (a native view drawn "
                + "over the web view, or a projected rect that does not match what is rendered). "
                + "Compare `ui screenshot` with the rect for \(aimedAt), and prefer a selector the "
                + "page itself vouches for"
        }
        var landed = "on an element that is not in this capture, not on \(aimedAt)"
        if let ref = verdict.landedOn {
            let what = after.nodes[ref]?.domCssSelector() ?? ref
            if verdict.relation == Relation.ancestor {
                landed = "on \(ref) ('\(what)'), which CONTAINS \(aimedAt) rather than being it"
            } else {
                landed = "on \(ref) ('\(what)'), not on \(aimedAt)"
            }
        }
        return "the touch arrived in the page at (\(verdict.at ?? "?")) \(landed), so this page's "
            + "DOM rects do not agree with what is rendered — the tap dispatched where the tree "
            + "said and the page was hit elsewhere. Re-capture (`ui report`) and compare the two "
            + "rects; on iOS `act activate --css` needs no coordinates at all"
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

    private static func isDescendant(_ snapshot: Snapshot, _ node: Node, ancestorRef: String) -> Bool {
        var current = node.parentRef.flatMap { snapshot.nodes[$0] }
        var seen = Set<String>()
        while let candidate = current, seen.insert(candidate.ref).inserted {
            if candidate.ref == ancestorRef { return true }
            current = candidate.parentRef.flatMap { snapshot.nodes[$0] }
        }
        return false
    }

    /// Is any frame ABOVE this node one the top document could not walk itself? Such a
    /// frame's document is another origin's: the witness cannot be installed in it and
    /// its events do not cross the boundary, so an absent record proves nothing.
    private static func insideOpaqueFrame(_ snapshot: Snapshot, _ node: Node) -> Bool {
        var current = node.parentRef.flatMap { snapshot.nodes[$0] }
        var seen = Set<String>()
        while let candidate = current, seen.insert(candidate.ref).inserted {
            if case .text(let opaque)? = candidate.custom["domFrameOpaque"], !opaque.isEmpty { return true }
            if case .text(let pierced)? = candidate.custom["domFramePierced"], !pierced.isEmpty { return true }
            current = candidate.parentRef.flatMap { snapshot.nodes[$0] }
        }
        return false
    }
}
