import Foundation

/// Resolves a selector to a screen point for input dispatch — the **action**
/// path, as opposed to `Render.findNode`'s inspection path.
///
/// The order it encodes is the architecture rule:
///
///   "Use the semantic tree first for movement and input; fall back to view
///    frames only when no semantic match exists."
///
/// This is the Swift half of a two-language contract: the Kotlin
/// `SelectorResolver` in `reticle-helper` is the Android half, and both are
/// pinned by `reticle-protocol/fixtures/selector-resolution.cases.json`. The
/// fixture exists because the two HAD drifted — iOS never consulted the semantic
/// tree, the two disagreed on whether a `--region` miss taps the whole node, and
/// first-match lookups iterated an unordered dictionary, which in Swift is
/// randomized per process. Change resolution here only together with a case
/// there, or the other platform ships the old answer.
public enum SelectorResolution {

    /// A resolved target: where to dispatch, how it was found, and the node it
    /// belongs to. `source` is evidence — it travels into the action trace, so an
    /// agent can tell a semantic hit from a char-grid approximation.
    public struct Resolved: Sendable, Equatable {
        public let point: Point
        public let source: String
        public let ref: String?

        public init(point: Point, source: String, ref: String?) {
            self.point = point
            self.source = source
            self.ref = ref
        }
    }

    /// A `--region` needle matched no discovered region, no region source, and no
    /// char-grid substring.
    ///
    /// This is deliberately an error rather than a fall-through to the node's
    /// centre: the caller asked for a phrase inside a control, and a row whose
    /// phrase could not be located is exactly the row where tapping the middle
    /// does something else (toggles the checkbox instead of opening the terms).
    /// A silent downgrade there looks like success.
    public struct RegionMiss: Error, CustomStringConvertible {
        public let needle: String
        public let ref: String
        public let regionCount: Int
        public let hasCharGrid: Bool

        public var description: String {
            "node \(ref) matched but no region or on-screen text matched '\(needle)' "
                + "(\(regionCount) discovered region(s), charGrid=\(hasCharGrid ? "yes" : "no")). "
                + "Refusing to tap the whole node instead — that would hit a different target. "
                + "List what IS addressable with `ui regions`."
        }
    }

    /// Resolves `selector` against one capture. Returns nil when nothing matched
    /// (the caller renders selector-miss diagnostics); throws `RegionMiss` or
    /// `Render.AmbiguousLabel` when a match was found but must not be guessed at.
    public static func resolve(
        snapshot: Snapshot,
        semantic: SemanticTree,
        selector: Selector
    ) throws -> Resolved? {
        // 0. An explicit point is the escape hatch for when resolution cannot
        //    work, so nothing may override it — not even a --region needle passed
        //    alongside it.
        if let point = selector.point {
            return Resolved(point: point, source: "point", ref: nil)
        }

        // 1. A sub-region inside the selected node: the multi-region case that
        //    neither tree can express, since both collapse the row to one node.
        if let needle = selector.region, !needle.isEmpty {
            guard let node = try viewNode(snapshot, selector) else { return nil }
            return try resolveRegion(node: node, needle: needle)
        }

        // 2. The semantic tree — the honest input surface, and the only one
        //    Compose/SwiftUI expose.
        if let testId = selector.testId,
           let r = resolved(semantic.findByTestId(testId), "semantic:testId") {
            return r
        }
        if let resourceId = selector.resourceId,
           let r = resolved(semantic.findByResourceId(resourceId), "semantic:resourceId") {
            return r
        }
        if let css = selector.cssSelector {
            // Through the shared matcher: an exact captured path first, then a real
            // structural match. Only a verbatim path used to resolve, so every short
            // form the docs promise silently missed.
            //
            // `try`, not `try?`: a selector the matcher does not implement must
            // PROPAGATE. Swallowing it turns "not understood" into "no such
            // element", which are different answers and lead to opposite next
            // actions — the shared fixture pins exactly this.
            if let node = try CssSelectorMatch.find(snapshot, css), let frame = node.frame {
                return Resolved(point: center(frame), source: "dom:css", ref: node.ref)
            }
        }
        if let ref = selector.ref,
           let node = semantic.node(ref), let frame = node.frame {
            return Resolved(point: center(frame), source: "semantic:ref", ref: ref)
        }
        if let label = selector.label,
           let hit = try Render.labelHit(snapshot, label), let frame = hit.node.frame {
            // `label:coincident` when several stacked views over one rect were
            // collapsed into this hit — the caller sees that the match was not a
            // clean single node without being blocked by it.
            return Resolved(point: center(frame),
                            source: hit.coincident ? "label:coincident" : "label",
                            ref: hit.node.ref)
        }

        // 3. View-tree frames, for a node the semantic projection dropped.
        if let node = try viewNode(snapshot, selector), let frame = node.frame {
            return Resolved(point: center(frame), source: "view", ref: node.ref)
        }
        return nil
    }

    // MARK: - Region

    /// 1. a discovered region whose label contains the needle (case-insensitive:
    ///    a11y labels are often case-normalized by the platform);
    /// 2. a region named by its SOURCE — `--region touchDelegate` — for channels
    ///    that are rect-only by nature and can never carry a label;
    /// 3. the char grid, matched VERBATIM. Not lower-cased: the grid maps
    ///    on-screen text in any language, and case-folding is locale-dependent.
    private static func resolveRegion(node: Node, needle: String) throws -> Resolved {
        if let region = node.regions.first(where: {
            ($0.label ?? "").range(of: needle, options: .caseInsensitive) != nil
        }), let point = region.tapPoint() {
            return Resolved(point: point, source: "region:\(region.source.rawValue)", ref: node.ref)
        }
        if let region = node.regions.first(where: {
            $0.source.rawValue.caseInsensitiveCompare(needle) == .orderedSame
        }), let point = region.tapPoint() {
            return Resolved(point: point, source: "region:\(region.source.rawValue)", ref: node.ref)
        }
        if let grid = node.charGrid {
            let text = grid.text as NSString
            let found = text.range(of: needle)
            if found.location != NSNotFound,
               let rect = grid.rangeRects(start: found.location, end: found.location + found.length).first {
                let source = grid.approximate ? "charGrid:approx" : "charGrid"
                return Resolved(point: Point(x: rect.centerX, y: rect.centerY), source: source, ref: node.ref)
            }
        }
        throw RegionMiss(
            needle: needle,
            ref: node.ref,
            regionCount: node.regions.count,
            hasCharGrid: node.charGrid != nil
        )
    }

    // MARK: - Lookup

    /// The view-tree node a selector points at, in the SAME precedence the
    /// whole-node path uses. One order for both paths: when the region path had
    /// its own (ref first), `--test-id X --ref Y` picked different nodes
    /// depending on whether `--region` was also present.
    private static func viewNode(_ snapshot: Snapshot, _ selector: Selector) throws -> Node? {
        if let testId = selector.testId { return firstNode(snapshot, { $0.testId == testId }) }
        if let resourceId = selector.resourceId { return firstNode(snapshot, { $0.resourceId == resourceId }) }
        if let css = selector.cssSelector { return try CssSelectorMatch.find(snapshot, css) }
        if let ref = selector.ref { return snapshot.nodes[ref] }
        // An ambiguous label PROPAGATES — the Kotlin twin throws here too. A
        // `try?` would collapse "unknowable" into "absent", the exact lie
        // `WaitVerdict` exists to prevent: the caller would read "the feature is
        // missing" where the truth is "the selector cannot be trusted".
        if let label = selector.label { return try Render.labelMatch(snapshot, label) }
        return nil
    }

    /// First matching node in **document order** — see `Snapshot.first(where:)`,
    /// which explains why this is not `nodes.values.first`.
    private static func firstNode(_ snapshot: Snapshot, _ match: (Node) -> Bool) -> Node? {
        snapshot.first(where: match)
    }

    private static func resolved(_ node: SemanticNode?, _ source: String) -> Resolved? {
        guard let node, let frame = node.frame else { return nil }
        return Resolved(point: center(frame), source: source, ref: node.ref)
    }

    private static func center(_ rect: Rect) -> Point {
        Point(x: rect.centerX, y: rect.centerY)
    }
}
