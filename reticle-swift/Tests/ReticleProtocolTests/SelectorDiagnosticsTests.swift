import XCTest
@testable import ReticleProtocol

/// Ported with `SelectorDiagnostics` from the Kotlin helper's `SelectorDiagnosticsTest`.
final class SelectorDiagnosticsTests: XCTestCase {
    private func sample() throws -> Snapshot {
        let json = """
        {"schemaVersion":1,"capturedAtMillis":0,"platform":"android",
         "screen":{"size":{"width":1080,"height":2400},"density":3},"rootRef":"app",
         "nodes":{
          "app":{"ref":"app","kind":"application","typeName":"Application","children":["button","dom"]},
          "button":{"ref":"button","parentRef":"app","kind":"view","typeName":"android.widget.Button",
            "role":"button","testId":"checkout.payButton","frame":{"x":10,"y":20,"width":100,"height":40},
            "isInteractive":true},
          "dom":{"ref":"dom","parentRef":"app","kind":"domNode","typeName":"DOMElement","role":"button",
            "text":"Pay","frame":{"x":100,"y":200,"width":80,"height":40},"isInteractive":true,
            "custom":{"domCssSelector":{"_type":"text","value":"#web-pay"},
                      "domTag":{"_type":"text","value":"button"},
                      "domId":{"_type":"text","value":"web-pay"}}}}}
        """
        return try ReticleJSON.decode(Snapshot.self, from: Data(json.utf8))
    }

    func testPointMissListsAvailableTestIds() throws {
        let message = SelectorDiagnostics.pointMiss(try sample(), Selector(testId: "checkout.missing"))
        XCTAssertTrue(message.contains("could not resolve selector 'testId=checkout.missing'"), message)
        XCTAssertTrue(message.contains("testId candidates"), message)
        XCTAssertTrue(message.contains("'checkout.payButton'"), message)
    }

    /// A node sharing nothing with the query is not a candidate for it; one that
    /// shares a token is offered by its shortest handle, not its lineage.
    func testACssMissListsOnlyCandidatesThatShareSomethingWithTheQuery() throws {
        let unrelated = SelectorDiagnostics.nodeMiss(try sample(), Selector(cssSelector: "#missing"))
        XCTAssertTrue(unrelated.contains("no matching node for selector 'css=#missing'"), unrelated)
        XCTAssertFalse(unrelated.contains("'#web-pay'"), unrelated)
        XCTAssertTrue(unrelated.contains("None of the"), unrelated)

        let related = SelectorDiagnostics.nodeMiss(try sample(), Selector(cssSelector: "button.web-pay"))
        XCTAssertTrue(related.contains("css candidates sharing part of 'button.web-pay'"), related)
        XCTAssertTrue(related.contains("'#web-pay'"), related)
    }

    /// `--label` resolves a screen whose only stable handle is the visible string,
    /// so an empty selector names it first.
    func testAnEmptySelectorNamesTheVisibleTextFlagFirst() throws {
        let message = SelectorDiagnostics.pointMiss(try sample(), Selector())
        let label = try XCTUnwrap(message.range(of: "--label"))
        let testId = try XCTUnwrap(message.range(of: "--test-id"))
        XCTAssertLessThan(label.lowerBound, testId.lowerBound, message)
        XCTAssertTrue(message.contains("--point x,y"), message)
    }

    /// ...and a `--label` miss does NOT claim no selector was given (the Kotlin
    /// original did, because label fell into its catch-all branch).
    func testALabelMissDoesNotSayNoSelectorWasGiven() throws {
        let message = SelectorDiagnostics.pointMiss(try sample(), Selector(label: "Nope"))
        XCTAssertTrue(message.contains("label=Nope"), message)
        XCTAssertFalse(message.contains("No selector was given"), message)
    }

    /// A ref is a traversal index; on a DOM screen the answer names css handles and
    /// does not blame scrolling.
    func testARefMissSaysWhatARefIsAndOffersDomHandles() throws {
        let message = SelectorDiagnostics.pointMiss(try sample(), Selector(ref: "r428"))
        XCTAssertTrue(message.contains("traversal INDEX"), message)
        XCTAssertTrue(message.contains("--css"), message)
        XCTAssertTrue(message.contains("'#web-pay'"), message)
        XCTAssertFalse(message.contains("recycling list"), message)
    }
}
