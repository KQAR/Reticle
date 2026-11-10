import Foundation

/// Human-facing diagnostics for a selector that matched nothing.
///
/// Ported from the Kotlin helper's `SelectorDiagnostics` so ONE implementation
/// explains a miss for both platforms: the host now renders `ui node` / `ui style`
/// for Android too, and iOS used to assemble a partial copy of these hints inline
/// (ref lifetime and scrolling only — no css ranking, no kernel or cross-origin
/// wall, no region labels).
///
/// Every walk is in document order (`Snapshot.documentOrder()`), not dictionary
/// order: a Swift dictionary iterates in a hash-seeded order, so the candidate list
/// would otherwise change between two runs of one command.
public enum SelectorDiagnostics {
    public static func pointMiss(_ snapshot: Snapshot, _ selector: Selector) -> String {
        "could not resolve selector '\(selector.describe())' to a point. \(hint(snapshot, selector))"
    }

    public static func nodeMiss(_ snapshot: Snapshot, _ selector: Selector) -> String {
        "no matching node for selector '\(selector.describe())'. \(hint(snapshot, selector))"
    }

    static func hint(_ snapshot: Snapshot, _ selector: Selector) -> String {
        let nodes = snapshot.documentOrder()
        let candidates: String?
        if selector.testId != nil {
            candidates = candidateList("testId", nodes.compactMap(\.testId))
        } else if selector.resourceId != nil {
            candidates = candidateList("resourceId", nodes.compactMap(\.resourceId))
        } else if let css = selector.cssSelector {
            candidates = cssCandidateList(nodes, css)
        } else if let ref = selector.ref {
            candidates = refMiss(nodes, ref)
        } else if selector.label == nil && selector.point == nil {
            // `--label` was missing from this list and that is how it stayed unused
            // while a real flow was driven by coordinates: on screens whose only
            // stable handle is the visible string (dialog buttons with generic ids —
            // `tvCancel` holding "Yes"), the one flag that would have worked was the
            // one the miss message did not mention. Named FIRST for that reason.
            candidates = "No selector was given. Use --label \"<visible text>\" when the "
                + "on-screen string is the only stable handle, or one of: --test-id, "
                + "--resource-id, --css, --ref, --alias @N, or --point x,y."
        } else {
            candidates = nil
        }
        let region = selector.region.flatMap { regionHint(snapshot, selector, $0) }
        // The recycling-list note is about a row that was never bound. Two cases where
        // it is a wrong lead rather than a weak one, both measured: a REF miss on a
        // screen with a DOM on it (the cause is renumbering, not scrolling), and a
        // PIERCING css miss on a screen with a cross-origin frame (the cause is browser
        // policy, and no amount of scrolling binds that document).
        let domPresent = nodes.contains { $0.kind == .domNode }
        let piercingIntoOpaqueFrame = (selector.cssSelector?.contains(">>>") ?? false)
            && nodes.contains { $0.domCrossOriginFrame() }
        let scroll = (selector.ref != nil && domPresent) || piercingIntoOpaqueFrame
            ? nil : scrollHint(nodes)
        return [candidates, region, scroll, kernelHint(nodes, selector), crossOriginHint(nodes, selector)]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// The wall behind a css miss when the screen carries a CROSS-ORIGIN frame:
    /// browser policy withholds that document, so nothing under the frame element
    /// was captured and no selector can reach it. Only for css — a page inside a
    /// frame cannot have contributed a testId/resourceId/ref.
    private static func crossOriginHint(_ nodes: [Node], _ selector: Selector) -> String? {
        guard selector.cssSelector != nil else { return nil }
        let frames = nodes.filter { $0.domCrossOriginFrame() }
        guard !frames.isEmpty else { return nil }
        let named = frames.map { frame -> String in
            let rect = frame.frame.map {
                " [\(Int($0.x)),\(Int($0.y)) \(Int($0.width))x\(Int($0.height))]"
            } ?? ""
            return frame.ref + rect
        }.joined(separator: ", ")
        return "Note: this screen has a cross-origin frame (\(named)) whose document browser policy "
            + "withholds, so NOTHING inside it is captured and no selector — `>>>` included — can "
            + "reach it. If the target is in there, a coordinate (`--point x,y`) is the only path; "
            + "`ui coverage` reports the frame's rect."
    }

    /// A `--ref` miss, which is almost never "there is no such element": refs are
    /// traversal indices, renumbered by any relayout or re-render. Say so, and on a
    /// DOM screen name css handles — which survive a re-render — rather than native
    /// refs, which cannot stand in for a DOM node.
    private static func refMiss(_ nodes: [Node], _ ref: String) -> String {
        let domNodes = nodes.filter { $0.kind == .domNode }
        let lifetime = "'\(ref)' is not in the current tree. A ref is a traversal INDEX, valid only "
            + "for the snapshot it came from: any relayout — or, in a WebView, any re-render — "
            + "renumbers the whole tree."
        if domNodes.isEmpty {
            return "\(lifetime) \(candidateList("ref", nodes.map(\.ref))) "
                + "Prefer a handle that survives a re-capture: --test-id / --resource-id / --label."
        }
        let interactive = domNodes.filter { $0.isInteractive || $0.role == "textField" }
        let handles = distinct((interactive.isEmpty ? domNodes : interactive).map(addressableHandle))
            .prefix(6)
        return "\(lifetime) This screen carries \(domNodes.count) DOM node(s), and a DOM node cannot "
            + "be substituted by any of the native refs in the tree. Address it with --css, which "
            + "survives a re-render (the matcher implements :nth-of-type(n), so a captured path can "
            + "be shortened by hand): \(handles.map { "'\($0)'" }.joined(separator: ", ")). "
            + "Re-run `ui report` / `ui compact --live` if you need the current refs."
    }

    /// A handle that can be RE-RESOLVED: id, then tag+classes, then the tail of the
    /// captured path. Unlike `shortCssHandle`, never a bare tag that matches the
    /// first of forty.
    private static func addressableHandle(_ node: Node) -> String {
        if let id = node.domId(), !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "#\(id)" }
        let tag = node.domTag() ?? ""
        let classes = node.domClasses().prefix(2).map { ".\($0)" }.joined()
        if !classes.isEmpty { return tag + classes }
        if let path = node.domCssSelector() { return pathTail(path) }
        return tag.isEmpty ? node.ref : tag
    }

    /// A `--css` miss on a third-party WebView kernel is not a wrong selector: that
    /// view has no DOM to match against, and no wait or retry will make one.
    private static func kernelHint(_ nodes: [Node], _ selector: Selector) -> String? {
        guard selector.cssSelector != nil else { return nil }
        let kernels = nodes.filter { $0.domKernelUnsupported() }
        guard !kernels.isEmpty else { return nil }
        let named = distinct(kernels.compactMap { $0.domKernelName() }).joined(separator: ", ")
        return "Note: this screen has a suspected third-party WebView kernel (\(named)). "
            + "Reticle's DOM bridge is typed on android.webkit.WebView, so that view has NO DOM "
            + "at any level — target it as a plain view (--test-id / --point) instead of by CSS."
    }

    /// A miss inside a recycling list is not the same failure as a wrong selector: a
    /// container that keeps only its visible window bound has NO node for a far-down
    /// row. When something can still scroll, state that fact.
    private static func scrollHint(_ nodes: [Node]) -> String? {
        let scrollable = nodes.filter { $0.scroll?.isScrollable == true }.prefix(3)
        guard !scrollable.isEmpty else { return nil }
        let described = scrollable.map { node in
            "'\(node.testId ?? node.resourceId ?? node.ref)' (\(node.scroll?.describe() ?? ""))"
        }.joined(separator: ", ")
        return "Note: the screen has scrollable content (\(described)); "
            + "a recycling list only binds its visible window, so an unbound row has no node yet."
    }

    private static func regionHint(_ snapshot: Snapshot, _ selector: Selector, _ region: String) -> String? {
        guard let node = nodeFor(snapshot, selector) else { return nil }
        let labels = distinct(node.regions.compactMap(\.label)).prefix(8)
        let regionPart = labels.isEmpty
            ? "No discovered sub-region labels on matched node."
            : "Region '\(region)' did not match discovered labels: "
                + labels.map { "'\($0)'" }.joined(separator: ", ") + "."
        guard let text = node.charGrid?.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return regionPart
        }
        return regionPart + " Node text sample: '\(String(text.prefix(80)))'."
    }

    private static func nodeFor(_ snapshot: Snapshot, _ selector: Selector) -> Node? {
        if let ref = selector.ref { return snapshot.nodes[ref] }
        if let testId = selector.testId { return snapshot.first { $0.testId == testId } }
        if let resourceId = selector.resourceId { return snapshot.first { $0.resourceId == resourceId } }
        if let css = selector.cssSelector { return snapshot.first { $0.domCssSelector() == css } }
        return nil
    }

    /// Candidates for a `--css` miss, ranked by how much of the query each DOM node
    /// carries (id, classes, tag), printed by the shortest handle that names it, and
    /// capped at six. A node sharing nothing with the query is not a candidate: an
    /// empty list beats an arbitrary one.
    private static func cssCandidateList(_ nodes: [Node], _ query: String) -> String {
        let wanted = queryTokens(query)
        let domNodes = nodes.filter { $0.kind == .domNode }
        // Stable sort: equal scores keep document order, like Kotlin's sortedByDescending.
        var scored: [(offset: Int, node: Node, score: Int)] = []
        for (offset, node) in domNodes.enumerated() {
            let score = cssScore(node, wanted)
            if score > 0 { scored.append((offset, node, score)) }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.offset < b.offset }
        let handles = distinct(scored.map { shortCssHandle($0.node) }).prefix(6)
        if handles.isEmpty {
            return domNodes.isEmpty
                ? "No DOM nodes were captured on this screen, so no css selector can match."
                : "None of the \(domNodes.count) captured DOM nodes carry any part of '\(query)' "
                    + "(its id, classes or tag). Read the tree with `ui compact --live` "
                    + "rather than guessing another selector."
        }
        return "css candidates sharing part of '\(query)': " + handles.map { "'\($0)'" }.joined(separator: ", ")
    }

    /// The id / class / tag names a query mentions, lowercased.
    private static func queryTokens(_ query: String) -> Set<String> {
        Set(query.split(whereSeparator: { $0 == " " || $0 == ">" || $0 == "\t" })
            .flatMap { $0.split(whereSeparator: { $0 == "#" || $0 == "." }) }
            .map { String($0.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
    }

    private static func cssScore(_ node: Node, _ wanted: Set<String>) -> Int {
        guard !wanted.isEmpty else { return 0 }
        var score = 0
        // An id is the most specific thing a query can name, so it outweighs the rest.
        if let id = node.domId()?.lowercased(), wanted.contains(id) { score += 4 }
        for cls in node.domClasses() where wanted.contains(cls.lowercased()) { score += 2 }
        if let tag = node.domTag()?.lowercased(), wanted.contains(tag) { score += 1 }
        return score
    }

    /// The shortest selector that names this node, rather than its lineage.
    private static func shortCssHandle(_ node: Node) -> String {
        if let id = node.domId(), !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "#\(id)" }
        let tag = node.domTag() ?? ""
        let classes = node.domClasses().prefix(2).map { ".\($0)" }.joined()
        if !tag.isEmpty || !classes.isEmpty { return tag + classes }
        return node.domCssSelector().map(pathTail) ?? node.ref
    }

    private static func pathTail(_ path: String) -> String {
        path.components(separatedBy: " > ").suffix(2).joined(separator: " > ")
    }

    private static func candidateList(_ kind: String, _ raw: [String]) -> String {
        let values = Array(distinct(raw.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).prefix(12))
        if values.isEmpty { return "No \(kind) candidates are present in the current snapshot." }
        return "\(kind) candidates (\(values.count)\(values.count == 12 ? "+" : "")): "
            + values.map { "'\($0)'" }.joined(separator: ", ")
    }

    private static func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
