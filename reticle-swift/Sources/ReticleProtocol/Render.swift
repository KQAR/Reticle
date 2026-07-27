import Foundation

/// Host-side text renderers over a snapshot, ported from the Kotlin helper's
/// `HelperRenderCommands`. These are pure functions over the protocol models, so
/// they are platform-neutral: the Swift host uses them to render an iOS snapshot
/// exactly as the Kotlin helper renders an Android one.
///
/// `outline` (the `@N` alias cache) is intentionally not yet ported; it is a
/// convenience layer tracked as a follow-up.
public enum Render {
    /// Render one of: tree / semantics / compact / node / regions / style.
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
        case "style": return style(snapshot)
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
        let lines = windowGrouped(snapshot, observation)
        // Lead with the keyboard state when it was probed: the keyboard is
        // invisible to the node walk, so without this line an agent has no way
        // to know that "tappable" items near the bottom would actually hit the
        // keys. Matches the Kotlin helper's rendering.
        // Focus loss outranks the keyboard line: when another window holds input
        // focus (a system prompt, presented by another process and therefore absent
        // from this tree) nothing here is tappable, however tappable it looks.
        let focusLine: String? = snapshot.screen.windowFocused == false
            ? "window: UNFOCUSED — another window has input focus (a system prompt is not part of "
                + "this app's tree); taps will not reach these items"
            : nil
        guard let kb = snapshot.screen.keyboard else {
            return ((focusLine.map { [$0] } ?? []) + lines).joined(separator: "\n")
        }
        let header: String
        if kb.visible {
            let whereStr = kb.frame.map { " [\($0.intDescription)]" } ?? ""
            let covered = observation.items.filter { $0.occludedBy == CompactObservation.occluderKeyboard }.count
            header = "keyboard: visible\(whereStr)"
                + (covered > 0 ? " — \(covered) item(s) occluded" : "")
                + " (dismiss with `act hide-keyboard`)"
        } else {
            header = "keyboard: hidden"
        }
        return ((focusLine.map { [$0] } ?? []) + [header] + lines).joined(separator: "\n")
    }

    /// Item lines grouped by window, topmost first, when more than one window has
    /// items — a stacked screen otherwise interleaves them by geometry and the
    /// screen being driven ends up scattered. Kept identical to the Kotlin helper's
    /// `WindowGrouping`. With one window the headers would be noise, and the output
    /// is unchanged.
    static func windowGrouped(_ snapshot: Snapshot, _ observation: CompactObservation) -> [String] {
        let present = Set(observation.items.compactMap { $0.windowRef })
        guard present.count > 1 else { return observation.items.map { $0.line() } }
        var out: [String] = []
        let top = snapshot.topWindowRef()
        for ref in snapshot.windowRefs().reversed() {
            let items = observation.items.filter { $0.windowRef == ref }
            if items.isEmpty { continue }
            out.append(windowHeader(snapshot.nodes[ref], ref: ref, top: ref == top))
            out.append(contentsOf: items.map { "  " + $0.line() })
        }
        let loose = observation.items.filter { $0.windowRef == nil }
        if !loose.isEmpty {
            out.append("window: (none) — nodes captured outside any window")
            out.append(contentsOf: loose.map { "  " + $0.line() })
        }
        return out
    }

    static func windowHeader(_ node: Node?, ref: String, top: Bool) -> String {
        let what = node?.testId
            ?? node?.resourceId
            ?? node?.typeName.split(separator: ".").last.map(String.init)
            ?? "window"
        let whereStr = node?.frame.map { " [\($0.intDescription)]" } ?? ""
        return "window \(ref) \(what)\(whereStr)" + (top ? " [top]" : " [behind the top window]")
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

    /// Geometry + style + provenance for every node that has any, in units a
    /// consumer can compare. Deliberately not a comparison: what the values ought
    /// to be, what tolerance counts, and which regions are exempt are the caller's
    /// policy. Matches the Kotlin helper's `renderStyle`.
    static func style(_ snapshot: Snapshot) -> String {
        StyleObservation.from(snapshot).render()
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
                let whereStr = rect.map { "[\($0.intDescription)]" } ?? "(no rect)"
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
            if let n = orderedRefs(snapshot).lazy.compactMap({ snapshot.nodes[$0] })
                .first(where: { $0.domCssSelector() == css }) { return n }
        }
        if let ref = selector.ref { return snapshot.nodes[ref] }
        if let label = selector.label { return try? labelMatch(snapshot, label) }
        return nil
    }

    /// Raised when a `label` selector matched more than one visible node. Picking
    /// the first would land a tap on the wrong row while looking successful.
    public struct AmbiguousLabel: Error, CustomStringConvertible {
        public let label: String
        public let matches: [Node]
        public var description: String {
            let listed = matches.prefix(6).map { n -> String in
                let text = n.text ?? n.contentDescription ?? "?"
                let at = n.frame.map { "\(Rect.whole($0.x)),\(Rect.whole($0.y))" } ?? "?"
                return "'\(text)' at \(at) (\(n.ref))"
            }.joined(separator: ", ")
            return "label '\(label)' matched \(matches.count) visible nodes: \(listed). "
                + "Refusing to guess — narrow it with --test-id / --resource-id / --ref, or use --point."
        }
    }

    /// The single visible node whose text / a11y label matches, for framework
    /// controls with no id of their own (alert buttons, menu rows). Exact match
    /// first, substring second, scoped to the topmost window; ambiguity throws
    /// rather than silently taking the first match.
    public static func labelMatch(_ snapshot: Snapshot, _ label: String) throws -> Node? {
        // Scope to the HIGHEST-stacked window that contains any candidate, not
        // simply the top window: on iOS the system keyboard is itself a window in
        // the scene, so a strict "top window only" rule would empty the candidate
        // set whenever it is up. This gives a popup precedence without that risk.
        let windowRefs = (snapshot.root()?.children ?? []).filter { snapshot.nodes[$0]?.kind == .window }
        func windowRef(of node: Node) -> String? {
            var current: Node? = node
            while let n = current {
                if n.kind == .window { return n.ref }
                current = n.parentRef.flatMap { snapshot.nodes[$0] }
            }
            return nil
        }
        let visible = orderedRefs(snapshot).compactMap { snapshot.nodes[$0] }.filter {
            $0.isVisible && $0.frame != nil
        }
        var candidates = visible
        for ref in windowRefs.reversed() {
            let scoped = visible.filter { windowRef(of: $0) == ref }
            if !scoped.isEmpty { candidates = scoped; break }
        }
        func textOf(_ node: Node) -> String? { node.text ?? node.contentDescription }
        let exact = candidates.filter { textOf($0)?.trimmingCharacters(in: .whitespacesAndNewlines) == label }
        let matches = exact.isEmpty
            ? candidates.filter { textOf($0)?.range(of: label, options: .caseInsensitive) != nil }
            : exact
        // Nested duplicates are not an ambiguity: a row container repeats its
        // child's text, and an alert button wraps a label with the same string at
        // nearly the same point. Drop any match that is an ANCESTOR of another and
        // keep the innermost; two matches in DIFFERENT subtrees stay ambiguous.
        func isAncestor(_ candidate: Node, of node: Node) -> Bool {
            var current = node.parentRef.flatMap { snapshot.nodes[$0] }
            while let n = current {
                if n.ref == candidate.ref { return true }
                current = n.parentRef.flatMap { snapshot.nodes[$0] }
            }
            return false
        }
        let leaves = matches.filter { node in !matches.contains { isAncestor(node, of: $0) } }
        if leaves.isEmpty { return nil }
        if leaves.count == 1 { return leaves[0] }
        throw AmbiguousLabel(label: label, matches: leaves)
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
