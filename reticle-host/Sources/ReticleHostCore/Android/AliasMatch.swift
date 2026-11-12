import Foundation
import ReticleProtocol

/// Re-finds a cached `@N` outline entry in a live tree, so a relayout between
/// `ui outline` and `act --alias` does not land the touch on stale coordinates.
///
/// Matched by the entry's stable selector (testId / resourceId / css) first, then by
/// label + role; among several matches (repeated list rows) the one nearest the
/// cached frame wins — that is the node the alias pointed at, wherever it moved.
/// Only visible nodes with a frame count.
///
/// The css branch is structural. `ui outline` caches the SHORTEST unique handle
/// `CssHandle` cut from the node's path (`#pay`, or a suffix of the path), and the
/// Kotlin original compared that string for equality with the live node's full
/// `domCssSelector` — which almost never held, so every DOM alias fell back to
/// label + role. A handle is always a path suffix or `#id`, inside the grammar
/// `CssSelectorMatch` speaks; one it cannot parse (it should not happen) is a miss.
enum AliasMatch {
    static func live(_ snapshot: Snapshot, _ entry: Outline.Entry) -> Node? {
        // Document order, so a tie in distance has one answer, not a dictionary's.
        let nodes = snapshot.documentOrder().filter { $0.isVisible && $0.frame != nil }
        var matched = nodes.filter { node in
            (entry.testId != nil && node.testId == entry.testId)
                || (entry.resourceId != nil && node.resourceId == entry.resourceId)
                || (entry.css.map { css in (try? CssSelectorMatch.matches(snapshot, node, css)) ?? false } ?? false)
        }
        if matched.isEmpty {
            guard let label = entry.label else { return nil }
            matched = nodes.filter { ($0.contentDescription ?? $0.text) == label && ($0.role ?? $0.typeName) == entry.role }
        }
        func distance(_ node: Node) -> Double {
            let dx = node.frame!.centerX - entry.frame.centerX, dy = node.frame!.centerY - entry.frame.centerY
            return dx * dx + dy * dy
        }
        // `min(by:)` keeps the first of equal elements, so document order breaks ties.
        return matched.min { distance($0) < distance($1) }
    }
}
