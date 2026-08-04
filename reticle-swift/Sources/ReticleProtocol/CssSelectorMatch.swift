import Foundation

/// Matching a CSS selector against captured DOM nodes — the Swift twin of
/// reticle-core's `CssSelectorMatch`.
///
/// `--css` used to be a string comparison against each node's captured
/// `domCssSelector`, the full ancestor path the traversal script emits. Only a
/// verbatim copy of that path could ever match, so the documented forms did not
/// work on a real page: `--css '#pay'` missed unless `#pay` happened to BE the
/// whole path, and `--css 'input.some-class'` missed on a page full of exactly
/// such inputs.
///
/// This matches structurally instead, over the tree Reticle already has: tag, id
/// and classes per node plus the parent chain. The grammar is small and its limits
/// are **refused rather than approximated** — an unsupported construct throws
/// `UnsupportedCssSelector` naming itself, because "not understood" and "no such
/// element" are different answers and only one of them means the element is absent.
///
/// Supported: type, `#id`, `.class` and their compounds; descendant and child
/// (`>`) combinators; the ` >>> ` piercing chain, which in this tree is an
/// ordinary descendant relationship (an open shadow root's children and a
/// same-origin iframe's body are captured as children of the host node); and
/// `:nth-of-type(n)` / `:nth-child(n)`, the one pseudo-class family the captured
/// paths are themselves built out of. The index is compared against the position
/// the PAGE reported (`domNthOfType` / `domNthChild`), never against a count of
/// captured siblings — the walk drops hidden elements, so counting here would
/// answer `:nth-of-type(3)` with the third VISIBLE sibling.
///
/// Refused by name: attribute selectors, every other pseudo-class and every
/// pseudo-element, the universal selector, sibling combinators, selector lists.
public enum CssSelectorMatch {

    /// A compound selector: at most one tag and id, any number of classes.
    private struct Compound {
        var tag: String?
        var id: String?
        var classes: [String] = []
        var nthOfType: Int?
        var nthChild: Int?

        func matches(_ node: Node) -> Bool {
            if let tag, node.domTag()?.lowercased() != tag.lowercased() { return false }
            if let id, node.domId() != id { return false }
            if !classes.isEmpty {
                let own = Set(node.domClasses())
                if !classes.allSatisfy({ own.contains($0) }) { return false }
            }
            // A node with no captured position cannot satisfy a positional query;
            // a capture with NO positions at all is reported as a refusal instead
            // (see `assertPositionsAreCaptured`).
            if let nthOfType, node.domNthOfType() != nthOfType { return false }
            if let nthChild, node.domNthChild() != nthChild { return false }
            return true
        }

        var isPositional: Bool { nthOfType != nil || nthChild != nil }
    }

    private enum Combinator { case descendant, child }

    private struct Step {
        let combinator: Combinator
        let compound: Compound
    }

    /// The node `selector` names, or nil.
    ///
    /// Exact captured-path equality first — a path copied verbatim out of a
    /// snapshot, `:nth-of-type` and all, is a legitimate way to name a node — then
    /// the structural match, which is what a caller would actually type. Document
    /// order, never map order: a `Dictionary`'s is hash-seeded per process.
    public static func find(_ snapshot: Snapshot, _ selector: String) throws -> Node? {
        if let exact = snapshot.first(where: { $0.domCssSelector() == selector }) { return exact }
        // Parse up front so an unsupported construct surfaces as a refusal rather
        // than as an empty result, whatever the caller does with the return value.
        let steps = try parse(selector)
        try assertPositionsAreCaptured(snapshot, selector, steps)
        return snapshot.first { node in
            node.kind == .domNode && ((try? matches(snapshot, node, selector)) ?? false)
        }
    }

    /// Does `node` match `selector` within `snapshot`?
    public static func matches(_ snapshot: Snapshot, _ node: Node, _ selector: String) throws -> Bool {
        let steps = try parse(selector)
        guard let subject = steps.last, subject.compound.matches(node) else { return false }
        return matchesAncestors(snapshot, node, Array(steps.dropLast()))
    }

    /// Walk the remaining steps right-to-left over the node's ancestors.
    /// Descendant steps backtrack, so this recurses: a failure further up must be
    /// able to try the next candidate ancestor.
    private static func matchesAncestors(_ snapshot: Snapshot, _ node: Node, _ steps: [Step]) -> Bool {
        guard let step = steps.last else { return true }
        let rest = Array(steps.dropLast())
        var current = node.parentRef.flatMap { snapshot.nodes[$0] }
        var seen = Set<String>()
        while let candidate = current, seen.insert(candidate.ref).inserted {
            if step.compound.matches(candidate), matchesAncestors(snapshot, candidate, rest) { return true }
            // A child combinator gets exactly one shot: the immediate parent.
            if step.combinator == .child { return false }
            current = candidate.parentRef.flatMap { snapshot.nodes[$0] }
        }
        return false
    }

    private static func parse(_ selector: String) throws -> [Step] {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw UnsupportedCssSelector(selector: selector, construct: "an empty selector") }
        let normalized = trimmed.replacingOccurrences(of: " >>> ", with: " ")
        // Pseudo-classes first, and by name: `:nth-of-type(2)` is supported while
        // `:hover` is not, so a blanket "contains a colon" refusal cannot tell them
        // apart. The char-level checks then run with the pseudo parts removed, so
        // their parens and digits trip nothing.
        try validatePseudos(selector, normalized)
        try rejectUnsupported(selector, pseudo.stringByReplacingMatches(
            in: normalized, range: NSRange(normalized.startIndex..., in: normalized), withTemplate: ""
        ))
        let steps = try tokenize(normalized, selector)
        if steps.isEmpty { throw UnsupportedCssSelector(selector: selector, construct: "no compound selectors") }
        return steps
    }

    private static func rejectUnsupported(_ original: String, _ normalized: String) throws {
        let constructs: [(Character, String)] = [
            ("[", "attribute selectors"),
            ("*", "the universal selector"),
            ("+", "the adjacent-sibling combinator"),
            ("~", "the general-sibling combinator"),
            (",", "selector lists"),
        ]
        for (character, name) in constructs where normalized.contains(character) {
            throw UnsupportedCssSelector(selector: original, construct: name)
        }
    }

    /// Every `:pseudo` / `:pseudo(arg)` in a selector.
    private static let pseudo = try! NSRegularExpression(
        pattern: ":([A-Za-z-]+)(?:\\(([^)]*)\\))?"
    )

    /// The pieces of one pseudo match: its name and its argument.
    private static func pseudoParts(_ selector: String) -> [(name: String, argument: String)] {
        let range = NSRange(selector.startIndex..., in: selector)
        return pseudo.matches(in: selector, range: range).map { match in
            func group(_ index: Int) -> String {
                guard let r = Range(match.range(at: index), in: selector) else { return "" }
                return String(selector[r])
            }
            return (group(1), group(2))
        }
    }

    /// Accept the two positional pseudo-classes the captured paths are built out of
    /// and refuse every other one BY NAME. `:nth-of-type(2n+1)` is refused as its own
    /// thing rather than as "a sibling combinator", which is what a character scan
    /// would have called the `+`.
    private static func validatePseudos(_ original: String, _ normalized: String) throws {
        for part in pseudoParts(normalized) {
            let name = part.name.lowercased()
            if name != "nth-of-type" && name != "nth-child" {
                throw UnsupportedCssSelector(
                    selector: original, construct: "the pseudo-class or pseudo-element ':\(part.name)'"
                )
            }
            guard let index = Int(part.argument.trimmingCharacters(in: .whitespaces)), index >= 1 else {
                throw UnsupportedCssSelector(
                    selector: original,
                    construct: "':\(name)(\(part.argument))' rather than a plain 1-based index — "
                        + "an an+b expression or a keyword argument is not implemented, only "
                        + "`:\(name)(2)`"
                )
            }
        }
    }

    /// A positional query against a capture with no positions in it is an
    /// agent/host version skew, not "no such element" — say so instead of missing.
    /// Only fires when NOTHING on the screen carries a position.
    private static func assertPositionsAreCaptured(
        _ snapshot: Snapshot, _ selector: String, _ steps: [Step]
    ) throws {
        guard steps.contains(where: { $0.compound.isPositional }) else { return }
        let domNodes = snapshot.nodes.values.filter { $0.kind == .domNode }
        if domNodes.isEmpty { return }
        if domNodes.contains(where: { $0.domNthOfType() != nil || $0.domNthChild() != nil }) { return }
        throw UnsupportedCssSelector(
            selector: selector,
            construct: "a positional pseudo-class this capture cannot answer: none of its "
                + "\(domNodes.count) DOM node(s) carry a sibling position, which means the app's "
                + "Reticle agent predates it — re-capture with a matching agent, or drop the "
                + "`:nth-…()` part"
        )
    }

    private static func tokenize(_ normalized: String, _ original: String) throws -> [Step] {
        var steps: [Step] = []
        var combinator = Combinator.descendant
        let padded = normalized.replacingOccurrences(of: ">", with: " > ")
        for token in padded.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            if token == ">" {
                combinator = .child
                continue
            }
            steps.append(Step(combinator: combinator, compound: try compound(String(token), original)))
            combinator = .descendant
        }
        return steps
    }

    private static func compound(_ token: String, _ original: String) throws -> Compound {
        var out = Compound(tag: nil, id: nil)
        // The pseudo parts were validated already; pull their indices out and parse
        // what is left as the plain tag/id/class compound it now is.
        for part in pseudoParts(token) {
            let index = Int(part.argument.trimmingCharacters(in: .whitespaces))
            switch part.name.lowercased() {
            case "nth-of-type": out.nthOfType = index
            case "nth-child": out.nthChild = index
            default:
                throw UnsupportedCssSelector(
                    selector: original, construct: "the pseudo-class ':\(part.name)'"
                )
            }
        }
        let bare = pseudo.stringByReplacingMatches(
            in: token, range: NSRange(token.startIndex..., in: token), withTemplate: ""
        )
        var name = ""
        var kind: Character = " "
        func flush() {
            guard !name.isEmpty else { return }
            switch kind {
            case "#": out.id = name
            case ".": out.classes.append(name)
            default: out.tag = name
            }
            name = ""
        }
        for character in bare {
            if character == "#" || character == "." {
                flush()
                kind = character
            } else {
                name.append(character)
            }
        }
        flush()
        return out
    }
}

/// A CSS selector using a construct `CssSelectorMatch` does not implement.
///
/// Thrown rather than answered `false`: a matcher that silently declines to
/// understand `:hover` reports the same thing as one that looked and found
/// nothing, and only one of those means "this element is not on screen".
public struct UnsupportedCssSelector: Error, CustomStringConvertible {
    public let selector: String
    public let construct: String

    public var description: String {
        "css selector '\(selector)' uses \(construct), which Reticle's matcher does not implement. "
            + "Supported: type, #id, .class and their compounds, with descendant / child (>) / "
            + "pierce (>>>) combinators, plus :nth-of-type(n) / :nth-child(n). A full path copied "
            + "verbatim out of a snapshot also still matches exactly."
    }
}
