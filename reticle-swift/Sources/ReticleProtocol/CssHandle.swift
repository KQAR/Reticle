import Foundation

/// The shortest `--css` that still names ONE node of this capture.
///
/// The traversal emits each DOM element's full ancestor path, because that is the
/// one form guaranteed to be unambiguous. Printing it is a different question, and
/// the answer was measured: on a real hybrid form every `ui outline` line carried a
/// ~400-character path, and one screen cost **17.8 KB** against 5.9 KB for the same
/// screen's `ui compact` — the view sold as the cheap ad-hoc loop was the most
/// expensive thing to read, by 3x, exactly where a hybrid app needs it most.
///
/// A path is only needed as far back as it takes to be unique, so:
///
///  1. `#id`, when the element has one and no other captured node repeats it;
///  2. the shortest **suffix** of the captured path that ends at a segment boundary
///     and matches exactly one captured node;
///  3. the full path, unchanged, when even that is not unique. Never a shorter form
///     that would resolve to a different node than the one being described.
///
/// Uniqueness is decided against the paths in THIS capture, which is the same set
/// `--css` will be matched against. Used by `Outline` (the `css=` slot) and by
/// `ScreenCoverage` (the `--css` a coordinate tap is told it could have used), so
/// the handle a hint names is the handle the outline prints.
public enum CssHandle {
    private static let child = " > "

    /// A per-snapshot index, so a projection that shortens 200 handles walks the
    /// node set once rather than once per handle.
    public struct Index {
        private let paths: [String]
        private let idCounts: [String: Int]
        /// Whether this capture can answer a `:nth-…()` at all: a capture from an
        /// agent that predates `domNthOfType` / `domNthChild` cannot, while its full
        /// path still resolves verbatim — so an old capture keeps its lineage.
        private let positional: Bool

        public init(_ snapshot: Snapshot) {
            let nodes = Array(snapshot.nodes.values)
            paths = nodes.compactMap { $0.domCssSelector() }
            idCounts = nodes
                .compactMap { $0.domId().flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
                .reduce(into: [:]) { $0[$1, default: 0] += 1 }
            positional = nodes.contains { $0.domNthOfType() != nil || $0.domNthChild() != nil }
        }

        private func matches(_ suffix: String) -> Int {
            paths.filter { $0 == suffix || $0.hasSuffix(CssHandle.child + suffix) }.count
        }

        public func of(_ node: Node) -> String? {
            guard let full = node.domCssSelector() else { return nil }
            if let id = node.domId(), !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, idCounts[id] == 1 {
                return "#\(id)"
            }
            let segments = full.components(separatedBy: CssHandle.child)
            // Longest-suffix-last: `full` itself is the last candidate and always
            // matches, so the loop cannot fall through to a wrong answer.
            for take in stride(from: 1, to: segments.count, by: 1) {
                let candidate = segments.suffix(take).joined(separator: CssHandle.child)
                if !positional && candidate.contains(":nth-") { continue }
                if matches(candidate) == 1 { return candidate }
            }
            return full
        }
    }
}
