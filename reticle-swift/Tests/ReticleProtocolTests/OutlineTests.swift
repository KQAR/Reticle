import XCTest
@testable import ReticleProtocol

/// Ported with `Outline` from the Kotlin helper's `OutlineRendererTest`.
final class OutlineTests: XCTestCase {
    private func snapshot(_ nodes: String, root: String = "app") throws -> Snapshot {
        let json = """
        {"schemaVersion":1,"capturedAtMillis":123,"platform":"android",
         "screen":{"size":{"width":1080,"height":2400},"density":3},"rootRef":"\(root)","nodes":{\(nodes)}}
        """
        return try ReticleJSON.decode(Snapshot.self, from: Data(json.utf8))
    }

    private func view(_ ref: String, parent: String = "app", role: String, testId: String, text: String,
                      y: Int, x: Int = 20, w: Int = 300, h: Int = 48, tappable: Bool = true) -> String {
        """
        "\(ref)":{"ref":"\(ref)","parentRef":"\(parent)","kind":"view","typeName":"android.widget.Button",
          "role":"\(role)","testId":"\(testId)","text":"\(text)",
          "frame":{"x":\(x),"y":\(y),"width":\(w),"height":\(h)},"isInteractive":\(tappable)}
        """
    }

    func testRendersAgentFacingAliasesInScreenOrder() throws {
        let s = try snapshot("""
        "app":{"ref":"app","kind":"application","typeName":"Application","children":["button","status"]},
        \(view("button", role: "button", testId: "checkout.payButton", text: "Pay", y: 200, x: 10, w: 100, h: 40)),
        \(view("status", role: "text", testId: "checkout.status", text: "Cart", y: 100, w: 200, h: 40, tappable: false))
        """)
        let (text, entries) = Outline.render(s)
        XCTAssertEqual(text, """
        Screen: 1080x2400 density=3.0
        @1 #checkout.status text "Cart" [20,100 200x40]
        @2 #checkout.payButton button "Pay" [10,200 100x40] tappable
        """)
        XCTAssertEqual(entries.map(\.alias), ["@1", "@2"])
    }

    func testMarksRepeatedVerticalItemsWithOrdinals() throws {
        let s = try snapshot("""
        "app":{"ref":"app","kind":"application","typeName":"Application","children":["one","two","three"]},
        \(view("one", role: "button", testId: "row.one", text: "One", y: 100)),
        \(view("two", role: "button", testId: "row.two", text: "Two", y: 160)),
        \(view("three", role: "button", testId: "row.three", text: "Three", y: 220))
        """)
        let (text, entries) = Outline.render(s)
        XCTAssertTrue(text.contains("@1 #row.one button \"One\" [20,100 300x48] tappable item 1/3"), text)
        XCTAssertTrue(text.contains("@3 #row.three button \"Three\" [20,220 300x48] tappable item 3/3"), text)
        XCTAssertEqual(entries.map(\.listIndex), [1, 2, 3])
        XCTAssertEqual(entries.map(\.listSize), [3, 3, 3])
    }

    /// A form pushed over a still-live host page: numbering starts in the top
    /// window, and item lines are never indented under the headers.
    func testGroupsAStackedScreenByWindowTopmostFirst() throws {
        func window(_ ref: String, _ kids: String) -> String {
            """
            "\(ref)":{"ref":"\(ref)","parentRef":"app","kind":"window","typeName":"DecorView",
              "frame":{"x":0,"y":0,"width":1000,"height":2000},"children":[\(kids)]}
            """
        }
        let s = try snapshot("""
        "app":{"ref":"app","kind":"application","typeName":"Application","children":["w1","w2"]},
        \(window("w1", "\"host.a\",\"host.b\"")),
        \(window("w2", "\"form.a\",\"form.b\"")),
        \(view("host.a", parent: "w1", role: "text", testId: "loanCard", text: "loanCard", y: 150)),
        \(view("form.a", parent: "w2", role: "text", testId: "firstName", text: "firstName", y: 100)),
        \(view("host.b", parent: "w1", role: "text", testId: "ivBg", text: "ivBg", y: 400)),
        \(view("form.b", parent: "w2", role: "text", testId: "lastName", text: "lastName", y: 300))
        """)
        let (text, entries) = Outline.render(s)
        let lines = text.components(separatedBy: "\n")
        let headers = lines.filter { $0.hasPrefix("window ") }
        XCTAssertEqual(headers.count, 2, text)
        XCTAssertTrue(headers[0].contains("[top]"), text)
        XCTAssertTrue(headers[1].contains("[behind the top window]"), text)
        XCTAssertEqual(entries.map(\.ref), ["form.a", "form.b", "host.a", "host.b"])
        XCTAssertEqual(entries.first?.windowRef, "w2")
        XCTAssertTrue(lines.contains { $0.hasPrefix("@1 #firstName ") }, text)
    }

    /// A container and its content at one top-left corner: the deepest node gets the
    /// lower alias, as it did when the agent's post-order node map decided the tie.
    func testNestedNodesSharingACornerListTheDeepestFirst() throws {
        func box(_ ref: String, parent: String, kids: String) -> String {
            """
            "\(ref)":{"ref":"\(ref)","parentRef":"\(parent)","kind":"view","typeName":"FrameLayout",
              "resourceId":"\(ref)","frame":{"x":0,"y":0,"width":1080,"height":2400},"children":[\(kids)]}
            """
        }
        let s = try snapshot("""
        "app":{"ref":"app","kind":"application","typeName":"Application","children":["outer"]},
        \(box("outer", parent: "app", kids: "\"inner\"")),
        \(box("inner", parent: "outer", kids: "\"scroller\"")),
        \(view("scroller", parent: "inner", role: "scrollView", testId: "home.scroller", text: "", y: 0, x: 0, w: 1080, h: 2400))
        """)
        XCTAssertEqual(Outline.render(s).entries.map(\.ref), ["scroller", "inner", "outer"])
    }

    func testOffScreenAndUnlabelledNodesAreNotAliased() throws {
        let s = try snapshot("""
        "app":{"ref":"app","kind":"application","typeName":"Application","children":["far","bare"]},
        \(view("far", role: "button", testId: "far", text: "Far", y: 10800)),
        "bare":{"ref":"bare","parentRef":"app","kind":"view","typeName":"View","frame":{"x":0,"y":0,"width":10,"height":10}}
        """)
        XCTAssertEqual(Outline.render(s).text, "Screen: 1080x2400 density=3.0\n(no visible labelled or interactive nodes)")
    }

    /// A DOM node prints its shortest unique handle, not its ~400-char lineage.
    func testDomNodesPrintTheirShortestUniqueCssHandle() throws {
        func dom(_ ref: String, _ path: String, y: Int) -> String {
            """
            "\(ref)":{"ref":"\(ref)","parentRef":"app","kind":"domNode","typeName":"DOMElement","role":"textField",
              "frame":{"x":0,"y":\(y),"width":100,"height":40},"isInteractive":true,
              "custom":{"domCssSelector":{"_type":"text","value":"\(path)"}}}
            """
        }
        let s = try snapshot("""
        "app":{"ref":"app","kind":"application","typeName":"Application","children":["a","b"]},
        \(dom("a", "body > div.form > input.first", y: 100)),
        \(dom("b", "body > div.form > input.last", y: 200))
        """)
        let text = Outline.render(s).text
        XCTAssertTrue(text.contains("@1 css=input.first textField"), text)
        XCTAssertTrue(text.contains("@2 css=input.last textField"), text)
    }

    /// The entry is also the alias-cache row and the helper's `aliasEntry`: nil
    /// fields are omitted and `windowRef` never leaves the host.
    func testEntryEncodesTheCacheShape() throws {
        let entry = Outline.Entry(alias: "@1", ref: "r", role: "button", label: nil,
                                  frame: Rect(x: 1, y: 2, width: 3, height: 4), testId: "t", resourceId: nil,
                                  css: nil, enabled: true, interactive: false, windowRef: "w1")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as! [String: Any]
        XCTAssertEqual(Set(object.keys), ["alias", "ref", "role", "frame", "testId", "enabled", "interactive"])
    }
}
