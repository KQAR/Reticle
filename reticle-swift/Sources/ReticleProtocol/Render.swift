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
        // Say that the projection folded something, once, at the end — the Kotlin
        // renderer's twin. The folded layers are anonymous and still in the
        // snapshot; a token-cheap view must not quietly read as the whole tree.
        let foldLine: String? = observation.collapsedWrappers > 0
            ? "(\(observation.collapsedWrappers) anonymous layer(s) folded into the node they wrap "
                + "— all still in the snapshot, reachable with `ui node --ref`)"
            : nil
        // Unlike the fold, a truncated item is GONE from this view; the line is
        // what keeps the cap from reading as "that was the whole screen".
        let truncLine: String? = observation.truncatedItems > 0
            ? "(\(observation.truncatedItems) more item(s) beyond this projection's cap — NOT listed here; "
                + "they are still in the snapshot, reachable with `ui tree` / `ui node --ref`)"
            : nil
        let tail = (foldLine.map { [$0] } ?? []) + (truncLine.map { [$0] } ?? [])
        guard let kb = snapshot.screen.keyboard else {
            return ((focusLine.map { [$0] } ?? []) + lines + tail)
                .joined(separator: "\n")
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
        return ((focusLine.map { [$0] } ?? []) + [header] + lines + tail)
            .joined(separator: "\n")
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
            out.append(contentsOf: items.map { $0.line() })
        }
        let loose = observation.items.filter { $0.windowRef == nil }
        if !loose.isEmpty {
            out.append("window: (none) — nodes captured outside any window")
            out.append(contentsOf: loose.map { $0.line() })
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
            let labelPart = label.map { " \"\($0.clipCodePoints(30))\"" } ?? ""
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
            let labelPart = node.label.map { " \"\($0.clipCodePoints(30))\"" } ?? ""
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
            let textPart = node.text.map { " \"\($0.clipCodePoints(40))\"" } ?? ""
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
                out += "    - \(r.source.rawValue) \"\(r.label.map { $0.clipCodePoints(40) } ?? "")\"\(target)\(color) \(whereStr)\n"
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
        try labelHit(snapshot, label)?.node
    }

    /// A label hit, and whether several coincident views were collapsed into it.
    public struct LabelHit: Sendable {
        public let node: Node
        public let coincident: Bool
    }

    /// [labelMatch], plus whether the match came from several views stacked on one
    /// rect — the caller reports that in `source` rather than hiding it.
    public static func labelHit(_ snapshot: Snapshot, _ label: String) throws -> LabelHit? {
        // Scope to the HIGHEST-stacked window whose candidates MATCH, not simply
        // the top window: on iOS the system keyboard is itself a window in the
        // scene, so a strict "top window only" rule would empty the candidate set
        // whenever it is up. The scope must key on windows that match — every
        // window has visible nodes (its own chrome at least), so "highest window
        // with any candidate" degenerates into the top-window trap this comment
        // warns about. Falls back to all visible nodes when no window matched,
        // which also covers nodes outside any window.
        let windowRefs = (snapshot.root()?.children ?? []).filter { snapshot.nodes[$0]?.kind == .window }
        // Guarded against parentRef cycles: a snapshot can come from disk or a
        // buggy agent, and an unguarded upward walk on a cyclic one never
        // terminates.
        func windowRef(of node: Node) -> String? {
            var seen = Set<String>()
            var current: Node? = node
            while let n = current, seen.insert(n.ref).inserted {
                if n.kind == .window { return n.ref }
                current = n.parentRef.flatMap { snapshot.nodes[$0] }
            }
            return nil
        }
        let visible = orderedRefs(snapshot).compactMap { snapshot.nodes[$0] }.filter {
            $0.isVisible && $0.frame != nil
        }
        // BOTH names, not one falling back to the other. A control that carries a
        // value AND an accessible label — `<input type=radio value="b"
        // aria-label="Plan B">` is the everyday case — had its label shadowed by
        // the value, so `--label "Plan B"` could not resolve the very control whose
        // only human-readable name is that label. See the Kotlin twin.
        // ...and the placeholder, which for an empty input is the ONLY text on
        // screen. See the Kotlin twin.
        func namesOf(_ node: Node) -> [String] {
            [node.text, node.contentDescription, node.domPlaceholder()].compactMap { $0 }
        }
        func matchesIn(_ candidates: [Node]) -> [Node] {
            let exact = candidates.filter { node in
                namesOf(node).contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == label }
            }
            return exact.isEmpty
                ? candidates.filter { node in
                    namesOf(node).contains { $0.range(of: label, options: .caseInsensitive) != nil }
                }
                : exact
        }
        var matches: [Node] = []
        for ref in windowRefs.reversed() {
            let scoped = visible.filter { windowRef(of: $0) == ref }
            if scoped.isEmpty { continue }
            let found = matchesIn(scoped)
            if !found.isEmpty { matches = found; break }
        }
        if matches.isEmpty { matches = matchesIn(visible) }
        // Nested duplicates are not an ambiguity: a row container repeats its
        // child's text, and an alert button wraps a label with the same string at
        // nearly the same point. Drop any match that is an ANCESTOR of another and
        // keep the innermost; two matches in DIFFERENT subtrees stay ambiguous.
        // Guarded like `windowRef(of:)`: a parentRef cycle must answer "no",
        // not loop forever.
        func isAncestor(_ candidate: Node, of node: Node) -> Bool {
            var seen = Set<String>()
            var current = node.parentRef.flatMap { snapshot.nodes[$0] }
            while let n = current, seen.insert(n.ref).inserted {
                if n.ref == candidate.ref { return true }
                current = n.parentRef.flatMap { snapshot.nodes[$0] }
            }
            return false
        }
        let leaves = matches.filter { node in !matches.contains { isAncestor(node, of: $0) } }
        // A caption and the control it names are not an ambiguity either. A form
        // states a field's name in a separate element and points the control at it
        // (`aria-labelledby`, `<label for>`), so ONE string legitimately belongs to
        // two nodes in different subtrees — and only one of them does anything when
        // tapped. Measured: a div-built dropdown and its `<span>` caption both
        // answered to "Education" and the refusal fired, leaving a coordinate as the
        // only way in — for the exact control this is meant to make reachable.
        // Two ACTIONABLE matches is still a refusal. See the Kotlin twin.
        let actionable = leaves.filter { $0.isInteractive }
        let candidates = actionable.count == 1 ? actionable : leaves
        if candidates.isEmpty { return nil }
        if candidates.count == 1 { return LabelHit(node: candidates[0], coincident: false) }
        // Same place, several layers: not an ambiguity. Measured on an iOS
        // simulator, `UIPickerView` draws its magnifier bands as separate table
        // views, so the row under the selection exists 3× at one spot ('09' at
        // 50,487 / 50,487 / 42,487) and a `--label "09"` tap on the wheel the docs
        // call tappable was REFUSED — precisely for the values nearest the
        // selection, the ones worth tapping. A tap resolves identically whichever
        // is picked, so refusing protects nothing. Rects genuinely apart stay
        // ambiguous, which is the case the rule exists for.
        if coincident(candidates) { return LabelHit(node: candidates[0], coincident: true) }
        throw AmbiguousLabel(label: label, matches: candidates)
    }

    /// Do all of these candidates sit on the SAME on-screen target? True when every
    /// candidate's tap point falls inside every other candidate's rect. The
    /// ancestor rule cannot catch this: these are siblings in DIFFERENT subtrees.
    /// Kept identical to the Kotlin `SelectorResolver.coincident`.
    static func coincident(_ candidates: [Node]) -> Bool {
        let frames = candidates.compactMap { $0.frame }
        guard frames.count == candidates.count else { return false }
        return frames.allSatisfy { a in frames.allSatisfy { b in b.contains(a.centerX, a.centerY) } }
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
