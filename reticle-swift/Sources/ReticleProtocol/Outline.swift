import Foundation

/// `ui outline`: the agent-facing "what can I act on right now" view, and the `@N`
/// entries the host caches so `act --alias @N` can find the node again.
///
/// Moved from the Kotlin helper's `OutlineRenderer` into the host (one
/// implementation, see AGENTS.md "Direction (2026-11)"). The cache file itself is
/// host I/O and lives in reticle-host; this is the pure half.
public enum Outline {
    /// One outline line. Encodes to the alias-cache entry shape and to the
    /// `aliasEntry` act parameter the helper re-resolves against the live tree.
    public struct Entry: Codable, Equatable, Sendable {
        public var alias: String
        public var ref: String
        public var role: String
        public var label: String?
        public var frame: Rect
        public var testId: String?
        public var resourceId: String?
        public var css: String?
        public var enabled: Bool
        public var interactive: Bool
        public var listIndex: Int?
        public var listSize: Int?
        /// The window this node lives in, for grouping; nil outside any window.
        /// Not cached: it only shapes the text.
        public var windowRef: String?

        enum CodingKeys: String, CodingKey {
            case alias, ref, role, label, frame, testId, resourceId, css, enabled, interactive, listIndex, listSize
        }
    }

    public static func render(_ snapshot: Snapshot) -> (text: String, entries: [Entry]) {
        let entries = collect(snapshot)
        let grouped = Set(entries.compactMap(\.windowRef)).count > 1
        var lines = ["Screen: \(Rect.whole(snapshot.screen.size.width))x\(Rect.whole(snapshot.screen.size.height))"
            + " density=\(snapshot.screen.density)"]
        if entries.isEmpty {
            lines.append("(no visible labelled or interactive nodes)")
        } else if !grouped {
            // One window: headers would be pure noise.
            lines += entries.map(line)
        } else {
            // Stacked screens interleave when flattened by geometry alone, so say
            // which window each run of nodes belongs to. Entries already come
            // topmost-window-first, so this only announces changes. Items are NOT
            // indented: that would break every `grep '^@N'` written against this.
            let top = snapshot.topWindowRef()
            var current: String?? = .none
            for entry in entries {
                if current != .some(entry.windowRef) {
                    current = .some(entry.windowRef)
                    lines.append(entry.windowRef.map {
                        Render.windowHeader(snapshot.nodes[$0], ref: $0, top: $0 == top)
                    } ?? "window: (none) — nodes captured outside any window")
                }
                lines.append(line(entry))
            }
        }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), entries)
    }

    private static func collect(_ snapshot: Snapshot) -> [Entry] {
        // Windows first (topmost first), geometry within a window: numbering starts
        // in the window the user is looking at, not a background screen's nodes.
        let windowOrder = Dictionary(uniqueKeysWithValues: snapshot.windowRefs().enumerated().map { ($1, $0) })
        // On screen, not merely in the tree: aliases are meant to be tapped, and a
        // node scrolled far past the fold is not a candidate (measured: 135 aliases
        // on a home screen where about 15 were actually visible).
        let screen = snapshot.screen.size
        let cssIndex = CssHandle.Index(snapshot)
        let candidates = postOrder(snapshot)
            .filter { $0.isVisible && $0.frame != nil && ($0.isInteractive || hasLabelOrSelector($0)) }
            .filter { onScreen($0, screen) }
            .map { (node: $0, window: snapshot.windowRefOf($0.ref)) }
        // Nodes sharing a top-left corner (a container and its content) keep post
        // order: the deepest, most specific node first. That is the order the Android
        // agent writes its node map in, which the Kotlin renderer inherited; the
        // index makes it explicit rather than dependent on the sort's stability.
        let sorted = candidates.enumerated().sorted { a, b in
            let wa = -(a.element.window.flatMap { windowOrder[$0] } ?? -1)
            let wb = -(b.element.window.flatMap { windowOrder[$0] } ?? -1)
            if wa != wb { return wa < wb }
            let fa = a.element.node.frame!, fb = b.element.node.frame!
            if fa.y != fb.y { return fa.y < fb.y }
            if fa.x != fb.x { return fa.x < fb.x }
            return a.offset < b.offset
        }.map(\.element)
        let entries = sorted.enumerated().map { index, item in
            Entry(
                alias: "@\(index + 1)",
                ref: item.node.ref,
                role: item.node.role ?? item.node.typeName,
                label: item.node.contentDescription ?? item.node.text,
                frame: item.node.frame!,
                testId: item.node.testId,
                resourceId: item.node.resourceId,
                css: cssIndex.of(item.node),
                enabled: item.node.isEnabled,
                interactive: item.node.isInteractive,
                windowRef: item.window
            )
        }
        return withListOrdinals(entries)
    }

    /// Children before their parent, from the root; nodes no walk reaches follow,
    /// by ref. Cycle-safe like `Snapshot.documentOrder()`.
    private static func postOrder(_ snapshot: Snapshot) -> [Node] {
        var seen = Set<String>()
        var out: [Node] = []
        func visit(_ ref: String) {
            guard seen.insert(ref).inserted, let node = snapshot.nodes[ref] else { return }
            node.children.forEach(visit)
            out.append(node)
        }
        visit(snapshot.rootRef)
        snapshot.nodes.keys.sorted().forEach(visit)
        return out
    }

    /// Does any part of this node's rect fall inside the display? Intersection, not
    /// containment: a row half off the bottom edge is still tappable.
    private static func onScreen(_ node: Node, _ screen: Size) -> Bool {
        guard let f = node.frame, f.width > 0, f.height > 0 else { return false }
        return f.x < screen.width && f.y < screen.height && f.x + f.width > 0 && f.y + f.height > 0
    }

    private static func hasLabelOrSelector(_ node: Node) -> Bool {
        node.testId != nil || node.resourceId != nil || node.contentDescription != nil
            || !(node.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || node.domCssSelector() != nil
    }

    /// `item i/n` for repeated same-shaped rows, so `@N` is not the only way to say
    /// "the third row".
    private static func withListOrdinals(_ entries: [Entry]) -> [Entry] {
        let groups = Dictionary(grouping: entries.indices, by: { listKey(entries[$0]) }).values.filter { $0.count >= 2 }
        guard !groups.isEmpty else { return entries }
        var out = entries
        for group in groups {
            let ordered = group.sorted {
                let a = entries[$0].frame, b = entries[$1].frame
                return a.y != b.y ? a.y < b.y : (a.x != b.x ? a.x < b.x : $0 < $1)
            }
            for (ordinal, i) in ordered.enumerated() {
                out[i].listIndex = ordinal + 1
                out[i].listSize = group.count
            }
        }
        return out
    }

    private static func listKey(_ entry: Entry) -> String {
        let f = entry.frame
        // Keyed by window too: two stacked screens can each hold a same-shaped row,
        // and merging them would report "item 3/8" for a list of four.
        return "\(entry.windowRef ?? "null")|\(entry.role)|\(Rect.whole(f.x / 24))|\(Rect.whole(f.width / 24))"
            + "|\(Rect.whole(f.height / 12))|\(entry.interactive)"
    }

    private static func line(_ entry: Entry) -> String {
        let selector = entry.testId.map { "#\($0)" } ?? entry.resourceId.map { "@\($0)" }
            ?? entry.css.map { "css=\($0)" } ?? entry.ref
        var out = "\(entry.alias) \(selector) \(entry.role)"
        if let label = entry.label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let clean = label.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            out += " \"\(clean.prefix(48))\""
        }
        out += " [\(entry.frame.intDescription)]"
        if !entry.enabled { out += " disabled" }
        if entry.interactive { out += " tappable" }
        if let index = entry.listIndex, let size = entry.listSize { out += " item \(index)/\(size)" }
        return out
    }
}
