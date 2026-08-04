import XCTest

@testable import ReticleProtocol

/// A DOM rect folded outside the view that draws it — the one case of a wrong
/// page-to-device fold that can be STATED rather than guessed at.
///
/// Mirrors `DomRectCheckTest` (Kotlin) verdict for verdict. Hand-written on both
/// sides rather than driven from a fixture because the rule is a single containment
/// test with no decision table to pin.
final class DomRectCheckTests: XCTestCase {

    func testARectInsideItsHostIsNotSuspect() {
        XCTAssertNil(DomRectCheck.outsideHost(tree(domY: 400), ref: "dom"))
    }

    func testARectFoldedAboveItsHostIsSuspectAndNamesTheHost() {
        // The shape measured on a real page: rects offset from what was on screen, so
        // the fold put the element outside the web view that renders it, and the tap
        // reported `settled=1` with nothing happening.
        let complaint = DomRectCheck.outsideHost(tree(domY: 20), ref: "dom")
        XCTAssertNotNil(complaint, "a rect above its host must be reported")
        XCTAssertTrue(complaint?.contains("checkout.webView") == true, "the host must be named")
        XCTAssertTrue(complaint?.contains("act activate --css") == true, "a next step must be named")
    }

    func testOnlyTheStrongCaseFires() {
        // A partially-visible element legitimately hangs over its host's edge, so
        // overlap alone proves nothing and would fire on ordinary screens.
        XCTAssertNil(DomRectCheck.outsideHost(tree(domY: 180), ref: "dom"))
        // A native node is never judged: there is no fold to be wrong.
        XCTAssertNil(DomRectCheck.outsideHost(tree(domY: 400), ref: "web"))
    }

    /// A web view at y=200..2200 with one DOM node whose top is `domY`.
    private func tree(domY: Double) -> Snapshot {
        var nodes: [String: Node] = [:]
        nodes["app"] = Node(
            ref: "app", kind: .application, typeName: "Application", children: ["web"]
        )
        nodes["web"] = Node(
            ref: "web", parentRef: "app", kind: .view, typeName: "WKWebView", role: "container",
            testId: "checkout.webView", frame: Rect(x: 0, y: 200, width: 1080, height: 2000),
            isInteractive: true, children: ["dom"]
        )
        nodes["dom"] = Node(
            ref: "dom", parentRef: "web", kind: .domNode, typeName: "DOMElement", role: "button",
            text: "Continue", frame: Rect(x: 100, y: domY, width: 800, height: 100),
            isInteractive: true
        )
        return Snapshot(
            capturedAtMillis: 0,
            platform: "ios",
            screen: ScreenInfo(size: Size(width: 1080, height: 2400), density: 3.0),
            rootRef: "app",
            nodes: nodes
        )
    }
}

/// `ui node --css` must tell "this syntax is not implemented" apart from "no such
/// element". The iOS path used to collapse them — a per-node `try?` swallowed the
/// matcher's refusal — so `--css 'div:hover'` reported a miss on iOS while the
/// Android helper refused it by name. Caught by the iOS e2e suite's first run of the
/// pseudo-class assertion.
final class NodeLookupCssRefusalTests: XCTestCase {

    func testAnUnsupportedConstructThrowsRatherThanMissing() {
        XCTAssertThrowsError(try Render.findNode(tree(), Selector(cssSelector: "div:hover"))) { error in
            XCTAssertTrue(error is UnsupportedCssSelector, "got \(error)")
        }
    }

    func testARealMissIsStillAMiss() throws {
        XCTAssertNil(try Render.findNode(tree(), Selector(cssSelector: "#no-such-id")))
    }

    func testASupportedSelectorStillResolves() throws {
        let match = try Render.findNode(tree(), Selector(cssSelector: "div#row"))
        XCTAssertEqual(match?.ref, "dom")
    }

    private func tree() -> Snapshot {
        var nodes: [String: Node] = [:]
        nodes["app"] = Node(ref: "app", kind: .application, typeName: "Application", children: ["dom"])
        nodes["dom"] = Node(
            ref: "dom", parentRef: "app", kind: .domNode, typeName: "DOMElement", role: "div",
            frame: Rect(x: 0, y: 0, width: 100, height: 40),
            custom: ["domTag": .text("div"), "domId": .text("row"), "domCssSelector": .text("#row")]
        )
        return Snapshot(
            capturedAtMillis: 0,
            platform: "ios",
            screen: ScreenInfo(size: Size(width: 400, height: 900), density: 3.0),
            rootRef: "app",
            nodes: nodes
        )
    }
}
