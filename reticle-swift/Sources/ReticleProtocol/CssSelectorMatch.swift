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
/// same-origin iframe's body are captured as children of the host node).
///
/// Refused by name: attribute selectors, pseudo-classes/elements (including the
/// `:nth-of-type` that appears in captured paths), the universal selector, sibling
/// combinators, selector lists.
public enum CssSelectorMatch {

    /// A compound selector: at most one tag and id, any number of classes.
    private struct Compound {
        var tag: String?
        var id: String?
        var classes: [String] = []

        func matches(_ node: Node) -> Bool {
            if let tag, node.domTag()?.lowercased() != tag.lowercased() { return false }
            if let id, node.domId() != id { return false }
            if !classes.isEmpty {
                let own = Set(node.domClasses())
                if !classes.allSatisfy({ own.contains($0) }) { return false }
            }
            return true
        }
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
        _ = try parse(selector)
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
        try rejectUnsupported(selector, normalized)
        let steps = tokenize(normalized)
        if steps.isEmpty { throw UnsupportedCssSelector(selector: selector, construct: "no compound selectors") }
        return steps
    }

    private static func rejectUnsupported(_ original: String, _ normalized: String) throws {
        let constructs: [(Character, String)] = [
            ("[", "attribute selectors"),
            (":", "pseudo-classes and pseudo-elements"),
            ("*", "the universal selector"),
            ("+", "the adjacent-sibling combinator"),
            ("~", "the general-sibling combinator"),
            (",", "selector lists"),
        ]
        for (character, name) in constructs where normalized.contains(character) {
            throw UnsupportedCssSelector(selector: original, construct: name)
        }
    }

    private static func tokenize(_ normalized: String) -> [Step] {
        var steps: [Step] = []
        var combinator = Combinator.descendant
        let padded = normalized.replacingOccurrences(of: ">", with: " > ")
        for token in padded.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }) {
            if token == ">" {
                combinator = .child
                continue
            }
            steps.append(Step(combinator: combinator, compound: compound(String(token))))
            combinator = .descendant
        }
        return steps
    }

    private static func compound(_ token: String) -> Compound {
        var out = Compound(tag: nil, id: nil)
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
        for character in token {
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
            + "pierce (>>>) combinators. A full path copied verbatim out of a snapshot also still "
            + "matches exactly."
    }
}
