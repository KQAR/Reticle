import XCTest
@testable import ReticleProtocol

/// The Swift half of the form-semantics contract; the Kotlin half is
/// `FormSemanticsTest` in reticle-core. Both platforms render one screen the same
/// way or the projection is not a shared contract — the whole reason
/// `CompactObservation` exists twice.
///
/// What these pin, all three measured on a real onboarding flow first: a toggle
/// state whose THIRD value is absence, a placeholder that is not the value, and an
/// error message that travels with the field it belongs to.
final class FormSemanticsTests: XCTestCase {

    /// Rows are stacked rather than co-located: the projection folds a wrapper
    /// into the node it hugs, and two fields sharing one rect would be folded
    /// together — an artefact of the fixture, not of what is under test.
    private func stacked(_ nodes: [Node]) -> [Node] {
        nodes.enumerated().map { index, node in
            var copy = node
            copy.frame = Rect(x: 60, y: 400 + Double(index) * 200, width: 960, height: 120)
            return copy
        }
    }

    private func snapshot(_ input: [Node]) -> Snapshot {
        let nodes = stacked(input)
        var all: [String: Node] = [
            "root": Node(
                ref: "root", kind: .application, typeName: "Application",
                children: nodes.map(\.ref)
            )
        ]
        for node in nodes { all[node.ref] = node }
        return Snapshot(
            capturedAtMillis: 0,
            platform: "android",
            screen: ScreenInfo(size: Size(width: 1080, height: 2400), density: 3),
            rootRef: "root",
            nodes: all
        )
    }

    private func field(
        _ ref: String,
        role: String = "textField",
        label: String? = nil,
        text: String? = nil,
        checked: CheckedState? = nil,
        custom: [String: MetadataValue] = [:]
    ) -> Node {
        Node(
            ref: ref, parentRef: "root", kind: .domNode, typeName: "DOMElement",
            role: role, contentDescription: label, text: text,
            frame: Rect(x: 60, y: 400, width: 960, height: 120),
            isInteractive: true, checked: checked, custom: custom
        )
    }

    private func line(_ ref: String, _ snapshot: Snapshot) -> String {
        CompactObservation.from(snapshot).items.first { $0.ref == ref }!.line()
    }

    func testATickedBoxAnUntickedBoxAndNoBoxAtAllAreThreeDifferentReadings() {
        let snap = snapshot([
            field("on", role: "checkbox", label: "Accept the terms", checked: .on),
            field("off", role: "checkbox", label: "Marketing email", checked: .off),
            field("mixed", role: "checkbox", label: "Select all", checked: .mixed),
            field("plain", label: "Not a checkbox"),
        ])

        XCTAssertTrue(line("on", snap).contains(" checked"))
        XCTAssertTrue(line("off", snap).contains(" unchecked"))
        XCTAssertTrue(line("mixed", snap).contains(" checked:mixed"))
        // Absence is the third state: a node that is not checkable must not borrow
        // `unchecked` and read like an untouched control.
        XCTAssertFalse(line("plain", snap).contains("checked"))
        XCTAssertNil(CompactObservation.from(snap).items.first { $0.ref == "plain" }?.checked)
    }

    func testAPlaceholderIsWhatTheFieldAsksForNotWhatItHolds() {
        let snap = snapshot([
            field("empty", custom: ["domPlaceholder": .text("Email")]),
            field("filled", text: "ada@example.com", custom: ["domPlaceholder": .text("Email")]),
        ])

        let empty = line("empty", snap)
        let filled = line("filled", snap)
        XCTAssertTrue(empty.contains("placeholder:\"Email\""))
        XCTAssertFalse(empty.contains("\"Email\" ["), "the placeholder must not stand in as the value")
        XCTAssertTrue(filled.contains("\"ada@example.com\""))
        XCTAssertTrue(filled.contains("placeholder:\"Email\""))
        XCTAssertNotEqual(empty, filled, "an empty and a filled field must not project identically")
    }

    func testAnInvalidFieldCarriesItsOwnMessage() {
        let snap = snapshot([
            field("named", custom: [
                "domInvalid": .bool(true),
                "domDescribedBy": .text("Enter a valid postcode"),
            ]),
            field("unnamed", custom: ["domInvalid": .bool(true)]),
            field("valid"),
        ])

        XCTAssertTrue(line("named", snap).contains("invalid:\"Enter a valid postcode\""))
        // Invalid-with-no-stated-reason is still not the same reading as valid.
        XCTAssertTrue(line("unnamed", snap).contains(" invalid"))
        XCTAssertFalse(line("unnamed", snap).contains("invalid:"))
        XCTAssertFalse(line("valid", snap).contains("invalid"))
        XCTAssertNil(snap.nodes["valid"]?.domInvalidMessage())
    }

    func testTheStateSurvivesTheWire() throws {
        let snap = snapshot([
            field("box", role: "checkbox", label: "Accept", checked: .off),
            field("field", custom: [
                "domPlaceholder": .text("Email"),
                "domInvalid": .bool(true),
                "domDescribedBy": .text("Required"),
            ]),
        ])
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(Snapshot.self, from: data)

        XCTAssertEqual(back.nodes["box"]?.checked, .off)
        XCTAssertEqual(back.nodes["field"]?.domPlaceholder(), "Email")
        XCTAssertEqual(back.nodes["field"]?.domInvalidMessage(), "Required")
        // Omit-defaults: a node with no toggle state must not gain one on the wire.
        XCTAssertNil(back.nodes["field"]?.checked)
    }
}
