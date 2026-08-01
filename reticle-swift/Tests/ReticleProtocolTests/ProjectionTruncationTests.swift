import XCTest
@testable import ReticleProtocol

/// The projection caps must SPEAK — the Swift half of the Kotlin
/// `ProjectionTruncationTest`. `compact` and `style` drop everything past their
/// item caps; the drop must be counted and rendered, and the wait digest must be
/// built past the cap so item #201 appearing still reads as a screen change.
final class ProjectionTruncationTests: XCTestCase {

    private func snapshot(buttons: Int) -> Snapshot {
        let root = Node(ref: "root", kind: .application, typeName: "Application",
                        children: (1...buttons).map { "b\($0)" })
        var nodes: [String: Node] = ["root": root]
        for i in 1...buttons {
            nodes["b\(i)"] = Node(
                ref: "b\(i)", parentRef: "root", kind: .view, typeName: "Button",
                role: "button", text: "Item \(i)",
                frame: Rect(x: 0, y: Double(i) * 100.0, width: 400, height: 90),
                isInteractive: true
            )
        }
        return Snapshot(
            capturedAtMillis: 0,
            platform: "ios",
            screen: ScreenInfo(size: Size(width: 400, height: 900), density: 3.0),
            rootRef: "root",
            nodes: nodes
        )
    }

    func testCompactCountsWhatTheCapDropped() {
        let observation = CompactObservation.from(snapshot(buttons: 5), maxItems: 3)
        XCTAssertEqual(observation.items.count, 3)
        XCTAssertEqual(observation.truncatedItems, 2)
    }

    func testCompactWithinTheCapReportsNothingTruncated() {
        XCTAssertEqual(CompactObservation.from(snapshot(buttons: 3)).truncatedItems, 0)
    }

    func testTheCompactRenderSaysWhatItsCapDropped() {
        let rendered = Render.compact(snapshot(buttons: 205))
        let last = rendered.split(separator: "\n").last.map(String.init) ?? ""
        XCTAssertTrue(last.contains("5 more item(s) beyond this projection's cap"), last)
    }

    func testStyleCountsWhatTheCapDroppedAndSaysSo() {
        let observation = StyleObservation.from(snapshot(buttons: 5), maxItems: 2)
        XCTAssertEqual(observation.items.count, 2)
        XCTAssertEqual(observation.truncatedItems, 3)
        let last = observation.render().split(separator: "\n").last.map(String.init) ?? ""
        XCTAssertTrue(last.contains("3 more style-bearing node(s)"), last)
    }

    func testAChangePastTheRenderCapStillChangesTheWaitDigest() {
        let before = CompactObservation.from(snapshot(buttons: 3), maxItems: .max)
        let after = CompactObservation.from(snapshot(buttons: 4), maxItems: .max)
        XCTAssertNotEqual(WaitProbe.digestOf(before), WaitProbe.digestOf(after))
    }

    func testFocusMovingBetweenFieldsChangesTheWaitDigest() {
        func snap(focused: String) -> Snapshot {
            let root = Node(ref: "root", kind: .application, typeName: "Application",
                            children: ["a", "b"])
            var nodes: [String: Node] = ["root": root]
            for ref in ["a", "b"] {
                nodes[ref] = Node(
                    ref: ref, parentRef: "root", kind: .view, typeName: "UITextField",
                    role: "textField", text: "field \(ref)",
                    frame: Rect(x: 0, y: ref == "a" ? 100 : 300, width: 400, height: 90),
                    isInteractive: true, isFocused: ref == focused
                )
            }
            return Snapshot(
                capturedAtMillis: 0,
                platform: "ios",
                screen: ScreenInfo(size: Size(width: 400, height: 900), density: 3.0),
                rootRef: "root",
                nodes: nodes
            )
        }
        XCTAssertNotEqual(
            WaitProbe.digestOf(CompactObservation.from(snap(focused: "a"))),
            WaitProbe.digestOf(CompactObservation.from(snap(focused: "b"))),
            "caret moving between fields is a screen change: same geometry, different armed field"
        )
    }
}
