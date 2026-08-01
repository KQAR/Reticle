#if canImport(UIKit)
import Foundation

/// Ordering for snapshot refs ("r0", "r1", …), which are assigned in walk
/// order: windows bottom-to-top, each window depth-first. "Deepest hit,
/// top-to-bottom" therefore means visiting refs in DESCENDING NUMERIC order —
/// a lexicographic sort on the raw strings puts "r9" after "r10" and breaks
/// that order on any screen with ten or more nodes, i.e. every real screen.
enum RefOrder {
    /// The numeric part of a ref; unparseable refs sort last.
    static func number(_ ref: String) -> Int {
        Int(ref.dropFirst()) ?? -1
    }

    /// Index entries, deepest/topmost walk position first.
    static func descending<V>(_ index: [String: V]) -> [(String, V)] {
        index.sorted { number($0.key) > number($1.key) }
    }
}
#endif
