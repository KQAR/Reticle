import Foundation

/// What actually reached a field after `act type` dispatched its text — the Swift
/// twin of the Android helper's `TypeReadback.classify`. Both are pinned by
/// `reticle-protocol/fixtures/type-readback.cases.json`.
///
/// Evidence, not a verdict: an app may transform what it is given (uppercase,
/// separators, `maxLength`), so `changed` claims nothing about who is wrong. Only
/// the loss shapes (`partial`, `dropped`, `none`) say characters went missing.
public enum TypeReadback {

    public enum Landed: String, Sendable {
        /// The typed text is in the field, verbatim.
        case exact
        /// Every typed letter and digit is there; formatting was added or removed.
        case reformatted
        /// A proper, non-empty prefix of the typed text. The burst-loss shape.
        case partial
        /// Into an empty field, the letters and digits that arrived are an in-order
        /// subsequence of the typed ones, with some missing.
        case dropped
        /// The field's text did not change.
        case none
        /// Changed into something not derivable from what was sent.
        case changed
    }

    public struct Verdict: Sendable, Equatable {
        public var landed: Landed
        public var landedChars: Int
    }

    public static func isLoss(_ landed: Landed) -> Bool {
        landed == .partial || landed == .none || landed == .dropped
    }

    /// Compare a field's text `before` and `after` typing `typed`. Typing inserts
    /// at the caret, so "it landed" is containment plus the length delta.
    public static func classify(before: String, after: String, typed: String) -> Verdict {
        if typed.isEmpty { return Verdict(landed: .exact, landedChars: 0) }
        if after == before { return Verdict(landed: .none, landedChars: 0) }
        if after.count - before.count == typed.count, after.contains(typed) {
            return Verdict(landed: .exact, landedChars: typed.count)
        }
        let typedCore = core(typed), beforeCore = core(before), afterCore = core(after)
        if !typedCore.isEmpty, afterCore.count == beforeCore.count + typedCore.count, afterCore.contains(typedCore) {
            return Verdict(landed: .reformatted, landedChars: typed.count)
        }
        // A proper prefix and nothing more: the characters arrived in order and
        // the tail was dropped.
        for n in stride(from: typed.count - 1, through: 1, by: -1) {
            let prefixCore = core(String(typed.prefix(n)))
            if prefixCore.isEmpty { continue }
            if afterCore.count == beforeCore.count + prefixCore.count, afterCore.contains(prefixCore) {
                return Verdict(landed: .partial, landedChars: n)
            }
        }
        // Only into an empty field, where all of the value came from the typing.
        // Case-sensitive, so an uppercasing app stays `changed`.
        if beforeCore.isEmpty, !afterCore.isEmpty, afterCore.count < typedCore.count,
           isSubsequence(afterCore, of: typedCore) {
            return Verdict(landed: .dropped, landedChars: afterCore.count)
        }
        return Verdict(landed: .changed, landedChars: 0)
    }

    /// Letters and digits only: what survives formatting.
    private static func core(_ s: String) -> String {
        String(s.filter { $0.isLetter || $0.isNumber })
    }

    private static func isSubsequence(_ inner: String, of outer: String) -> Bool {
        var it = inner.makeIterator()
        var want = it.next()
        for c in outer where c == want { want = it.next() }
        return want == nil
    }
}
