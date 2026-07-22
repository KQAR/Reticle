import Foundation

/// Host-side text renderers over a snapshot, ported from the Kotlin helper's
/// `HelperRenderCommands`. These are pure functions over the protocol models, so
/// they are platform-neutral: the Swift host uses them to render an iOS snapshot
/// exactly as the Kotlin helper renders an Android one.
///
/// `outline` (the `@N` alias cache) is intentionally not yet ported; it is a
/// convenience layer tracked as a follow-up.
public enum Render {
    /// Render one of: tree / semantics / compact / node / regions.
    /// `node` requires `selector`. Returns rendered text.
    public static func view(
        _ view: String,
        snapshot: Snapshot,
        depth: Int = .max,
        selector: Selector? = nil
    ) throws -> String {
        switch view {
        case "tree": return tree(snapshot, maxDepth: depth)
        case "semantics": return semantics(SemanticTree.build(from: snapshot), maxDepth: depth)
        case "compact": return compact(snapshot)
        case "node": return try node(snapshot, selector: selector)
        case "regions": return regions(snapshot)
        default: throw RenderError.unknownView(view)
        }
    }

    public enum RenderError: Error, CustomStringConvertible {
        case unknownView(String)
        case noSelector
        case nodeNotFound(String)

        public var description: String {
            switch self {
            case .unknownView(let v): return "unknown render view '\(v)'"
            case .noSelector: return "node render needs a selector (testId/resourceId/ref)"
            case .nodeNotFound(let s): return "no node matched selector \(s)"
            }
        }
    }

    private static func sel(testId: String?, resourceId: String?, ref: String) -> String {
        if let testId { return "#\(testId)" }
        if let resourceId { return "@\(resourceId)" }
        return ref
    }

    static func compact(_ snapshot: Snapshot) -> String {
        let observation = CompactObservation.from(snapshot)
        let lines = observation.items.map { $0.line() }
        // Lead with the keyboard state when it was probed: the keyboard is
        // invisible to the node walk, so without this line an agent has no way
        // to know that "tappable" items near the bottom would actually hit the
        // keys. Matches the Kotlin helper's rendering.
        guard let kb = snapshot.screen.keyboard else { return lines.joined(separator: "\n") }
        let header: String
        if kb.visible {
            let whereStr = kb.frame.map { " [\(Int($0.x)),\(Int($0.y)) \(Int($0.width))x\(Int($0.height))]" } ?? ""
            let covered = observation.items.filter { $0.occludedBy == CompactObservation.occluderKeyboard }.count
            header = "keyboard: visible\(whereStr)"
                + (covered > 0 ? " — \(covered) item(s) occluded" : "")
                + " (dismiss with `act hide-keyboard`)"
        } else {
            header = "keyboard: hidden"
        }
        return ([header] + lines).joined(separator: "\n")
    }

    static func tree(_ snapshot: Snapshot, maxDepth: Int) -> String {
        var out = ""
        func walk(_ ref: String, _ depth: Int) {
            if depth > maxDepth { return }
            guard let node = snapshot.nodes[ref] else { return }
            let s = sel(testId: node.testId, resourceId: node.resourceId, ref: node.ref)
            let label = node.text ?? node.contentDescription
            let labelPart = label.map { " \"\(String($0.prefix(30)))\"" } ?? ""
            out += String(repeating: "  ", count: depth) + "\(s) \(node.role ?? node.typeName)\(labelPart)\n"
            for c in node.children { walk(c, depth + 1) }
        }
        walk(snapshot.rootRef, 0)
        return trimEnd(out)
    }

    static func semantics(_ tree: SemanticTree, maxDepth: Int) -> String {
        var out = ""
        func walk(_ ref: String, _ depth: Int) {
            if depth > maxDepth { return }
            guard let node = tree.nodes[ref] else { return }
            let s = sel(testId: node.testId, resourceId: node.resourceId, ref: node.ref)
            let labelPart = node.label.map { " \"\(String($0.prefix(30)))\"" } ?? ""
            out += String(repeating: "  ", count: depth) + "\(s) \(node.role)\(labelPart)\n"
            for c in node.children { walk(c, depth + 1) }
        }
        let roots = orderedSemanticRefs(tree).filter {
            guard let n = tree.nodes[$0] else { return false }
            return n.parentRef == nil || tree.nodes[n.parentRef!] == nil
        }
        if roots.isEmpty { out = "(no semantic nodes)" } else { roots.forEach { walk($0, 0) } }
        return trimEnd(out)
    }

    static func node(_ snapshot: Snapshot, selector: Selector?) throws -> String {
        guard let selector else { throw RenderError.noSelector }
        guard let match = findNode(snapshot, selector) else {
            throw RenderError.nodeNotFound(selector.describe())
        }
        let data = try ReticleJSON.encodePretty(match)
        return String(decoding: data, as: UTF8.self)
    }

    static func regions(_ snapshot: Snapshot) -> String {
        var out = ""
        var any = false
        for ref in orderedRefs(snapshot) {
            guard let node = snapshot.nodes[ref] else { continue }
            if node.regions.isEmpty && !node.suspectedMultiRegion { continue }
            any = true
            let s = sel(testId: node.testId, resourceId: node.resourceId, ref: node.ref)
            let textPart = node.text.map { " \"\(String($0.prefix(40)))\"" } ?? ""
            out += "\(s) \(node.role ?? node.typeName)\(textPart)\n"
            if node.suspectedMultiRegion {
                out += "    ! suspectedMultiRegion: self-drawn control\n"
                if let g = node.charGrid {
                    out += "    charGrid: \(g.lines.count) line(s)\(g.approximate ? " (approximate)" : "")\n"
                }
            }
            for r in node.regions {
                let rect = r.rects.first
                let whereStr = rect.map { "[\(Int($0.x)),\(Int($0.y)) \(Int($0.width))x\(Int($0.height))]" } ?? "(no rect)"
                let target = r.target.map { " -> \($0)" } ?? ""
                let color = r.color.map { " color=\($0)" } ?? ""
                out += "    - \(r.source.rawValue) \"\(r.label.map { String($0.prefix(40)) } ?? "")\"\(target)\(color) \(whereStr)\n"
            }
        }
        if !any { out = "(no multi-region nodes found)" }
        return trimEnd(out)
    }

    /// Resolve a node from the view tree by selector: testId, then resourceId,
    /// then CSS selector (an exact match on a domNode's emitted
    /// `domCssSelector`, mirroring the Kotlin helper), then ref. (Point is an
    /// action concern, not an inspection one.)
    public static func findNode(_ snapshot: Snapshot, _ selector: Selector) -> Node? {
        if let testId = selector.testId {
            if let n = orderedRefs(snapshot).lazy.compactMap({ snapshot.nodes[$0] }).first(where: { $0.testId == testId }) { return n }
        }
        if let resourceId = selector.resourceId {
            if let n = orderedRefs(snapshot).lazy.compactMap({ snapshot.nodes[$0] }).first(where: { $0.resourceId == resourceId }) { return n }
        }
        if let css = selector.cssSelector {
            if let n = orderedRefs(snapshot).lazy.compactMap({ snapshot.nodes[$0] }).first(where: { node in
                if case .text(let v)? = node.custom["domCssSelector"] { return v == css }
                return false
            }) { return n }
        }
        if let ref = selector.ref { return snapshot.nodes[ref] }
        return nil
    }

    private static func orderedRefs(_ snapshot: Snapshot) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func visit(_ ref: String) {
            guard !seen.contains(ref), let node = snapshot.nodes[ref] else { return }
            seen.insert(ref)
            out.append(ref)
            for c in node.children { visit(c) }
        }
        visit(snapshot.rootRef)
        for ref in snapshot.nodes.keys.sorted() where !seen.contains(ref) { visit(ref) }
        return out
    }

    private static func orderedSemanticRefs(_ tree: SemanticTree) -> [String] {
        // Stable order: roots first (in sorted ref order), each followed by DFS.
        var out: [String] = []
        var seen = Set<String>()
        func visit(_ ref: String) {
            guard !seen.contains(ref), let node = tree.nodes[ref] else { return }
            seen.insert(ref)
            out.append(ref)
            for c in node.children { visit(c) }
        }
        visit(tree.rootRef)
        for ref in tree.nodes.keys.sorted() where !seen.contains(ref) { visit(ref) }
        return out
    }

    private static func trimEnd(_ s: String) -> String {
        var t = s
        while let last = t.last, last == "\n" || last == " " { t.removeLast() }
        return t
    }
}
