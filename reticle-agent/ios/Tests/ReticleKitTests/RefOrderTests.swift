import XCTest
@testable import ReticleKit

/// The point-hit walk order. Refs are numeric ("r9" comes before "r10"); a
/// lexicographic sort inverts them and the deepest-hit rule silently picks a
/// shallower view — on any screen with ten or more nodes, i.e. every screen.
final class RefOrderTests: XCTestCase {

    func testDescendingIsNumericNotLexicographic() {
        let index = Dictionary(uniqueKeysWithValues: (0...12).map { ("r\($0)", $0) })
        let refs = RefOrder.descending(index).map(\.0)
        XCTAssertEqual(refs, (0...12).reversed().map { "r\($0)" })
    }

    func testUnparseableRefsSortLast() {
        let refs = RefOrder.descending(["r2": 0, "weird": 0, "r10": 0]).map(\.0)
        XCTAssertEqual(refs, ["r10", "r2", "weird"])
    }
}
