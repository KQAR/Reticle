import XCTest
@testable import ReticleProtocol

/// What a DOM node's handle costs to PRINT, which is a different question from what
/// the traversal has to capture.
///
/// Measured on a real hybrid form: every `ui outline` line carried the element's
/// full ancestor path (~400 characters), and one screen cost 17.8 KB against 5.9 KB
/// for the same screen's `ui compact`.
///
/// The rule under test: shorten to the point of uniqueness, never past it. A handle
/// that resolves to a DIFFERENT node than the one it labels would be worse than the
/// 400 characters, so one case re-resolves every handle through the matcher that
/// will actually be given it. Ported from the Kotlin `CssHandleTest` when the Kotlin
/// implementation was deleted.
final class CssHandleTests: XCTestCase {

    /// A real Vue form's shape: N rows, each `div.form-row > div.body > input`.
    private struct Page {
        var nodes: [String: Node] = [:]

        init(rows: Int, positional: Bool = true, ids: Bool = false) {
            nodes["app"] = Node(ref: "app", kind: .application, typeName: "Application", children: ["web"])
            nodes["web"] = Node(
                ref: "web", parentRef: "app", kind: .view, typeName: "android.webkit.WebView",
                role: "webView", frame: Rect(x: 0, y: 0, width: 1080, height: 2400),
                isInteractive: true, children: ["body"]
            )
            func add(_ ref: String, _ parent: String, _ tag: String, _ cls: String?, _ path: String,
                     _ nth: Int, _ role: String, id: String? = nil, children: [String] = []) {
                var custom: [String: MetadataValue] = ["domTag": .text(tag), "domCssSelector": .text(path)]
                if let cls { custom["domClass"] = .text(cls) }
                if let id { custom["domId"] = .text(id) }
                if positional {
                    custom["domNthOfType"] = .integer(Int64(nth))
                    custom["domNthChild"] = .integer(Int64(nth))
                }
                nodes[ref] = Node(
                    ref: ref, parentRef: parent, kind: .domNode, typeName: "DOMElement", role: role,
                    frame: Rect(x: 0, y: 0, width: 100, height: 20), isInteractive: role == "textField",
                    custom: custom, children: children
                )
            }
            let bodyPath = "body:nth-of-type(1)"
            add("body", "web", "body", nil, bodyPath, 1, "body", children: (1...rows).map { "row\($0)" })
            for i in 1...rows {
                let rowPath = "\(bodyPath) > div.form-row:nth-of-type(\(i))"
                let fieldPath = "\(rowPath) > div.ep-form-field__body:nth-of-type(1)"
                add("row\(i)", "body", "div", "form-row", rowPath, i, "div", children: ["body\(i)"])
                add("body\(i)", "row\(i)", "div", "ep-form-field__body", fieldPath, 1, "div", children: ["input\(i)"])
                add("input\(i)", "body\(i)", "input", "ep-form-base-input__control",
                    "\(fieldPath) > input.ep-form-base-input__control:nth-of-type(1)", 1, "textField",
                    id: ids ? "amount" : nil)
            }
        }

        var snapshot: Snapshot {
            Snapshot(capturedAtMillis: 0, platform: "android",
                     screen: ScreenInfo(size: Size(width: 1080, height: 2400), density: 3),
                     rootRef: "app", nodes: nodes)
        }

        func input(_ i: Int) -> Node { nodes["input\(i)"]! }
        func handle(_ i: Int) -> String? { CssHandle.Index(snapshot).of(input(i)) }
    }

    func testAnIdWinsOverEveryPath() {
        XCTAssertEqual(Page(rows: 1, ids: true).handle(1), "#amount")
    }

    func testARepeatedIdIsNotAHandle() {
        // Two elements with one id is invalid HTML and entirely ordinary in the wild.
        // `#amount` would then name whichever the matcher reached first.
        XCTAssertNotEqual(Page(rows: 2, ids: true).handle(2), "#amount")
    }

    func testTheTailAloneIsEnoughWhenNothingElseSharesIt() {
        XCTAssertEqual(Page(rows: 1).handle(1), "input.ep-form-base-input__control:nth-of-type(1)")
    }

    func testItGrowsUntilItNamesOneNodeAndStopsThere() throws {
        // Three identical rows: the tail is ambiguous and the row index is what tells
        // them apart, so the handle must reach that segment and go no further.
        let page = Page(rows: 3)
        let handle = try XCTUnwrap(page.handle(3))
        XCTAssertTrue(handle.hasPrefix("div.form-row:nth-of-type(3)"), handle)
        XCTAssertTrue(handle.hasSuffix("input.ep-form-base-input__control:nth-of-type(1)"), handle)
        XCTAssertLessThan(handle.count, try XCTUnwrap(page.input(3).domCssSelector()).count)
    }

    func testANativeNodeHasNoCssHandleAtAll() {
        let native = Node(ref: "n", parentRef: "app", kind: .view, typeName: "android.widget.Button",
                          role: "button", testId: "pay")
        XCTAssertNil(CssHandle.Index(Page(rows: 1).snapshot).of(native))
    }

    func testACaptureThatCannotAnswerAPositionKeepsItsFullPath() {
        // An agent predating `domNthOfType` cannot answer `:nth-of-type(n)`, and the
        // matcher refuses such a selector by name — while the full path still matches
        // verbatim. Shortening there would trade a handle that works for one refused.
        let page = Page(rows: 3, positional: false)
        XCTAssertEqual(page.handle(3), page.input(3).domCssSelector())
    }

    func testEveryShortenedHandleReResolvesToItsOwnNode() throws {
        for rows in 1...4 {
            let page = Page(rows: rows)
            let snapshot = page.snapshot
            let index = CssHandle.Index(snapshot)
            for i in 1...rows {
                let handle = try XCTUnwrap(index.of(page.input(i)))
                XCTAssertEqual(try CssSelectorMatch.find(snapshot, handle)?.ref, "input\(i)",
                               "handle '\(handle)' re-resolved elsewhere")
            }
        }
    }
}
