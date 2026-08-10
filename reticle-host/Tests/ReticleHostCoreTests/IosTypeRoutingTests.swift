import Testing
import ReticleProtocol
@testable import ReticleHostIos

/// Typing is routed by what the target IS, not by which flag named it.
///
/// A DOM node has no UIKit responder to type into — a `WKWebView` does not
/// publish one — so it needs the page-level path regardless of whether the
/// caller said `--css` or `--ref`. The routing used to key off the selector's
/// kind, which broke the most natural loop there is: read `ui compact`, copy a
/// ref, `act type --ref`. Measured on a real device against a web KYC form, that
/// answered `unsupported_text_target: … (first responder after the touch:
/// WKWebView)` for a field the same node's `--css` typed into fine.
@Suite("iOS type routing by node kind")
struct IosTypeRoutingTests {

    private let chain = "div.form:nth-of-type(1) > input.rv-input__control:nth-of-type(1)"

    private func snapshot(_ nodes: [Node]) -> Snapshot {
        Snapshot(
            capturedAtMillis: 0, platform: "ios",
            screen: ScreenInfo(size: Size(width: 400, height: 800), density: 3),
            rootRef: "r0",
            nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.ref, $0) }))
    }

    private func domNode(_ ref: String, selector: String?) -> Node {
        Node(ref: ref, kind: .domNode, typeName: "DOMElement",
             frame: Rect(x: 0, y: 0, width: 10, height: 10),
             custom: selector.map { ["domCssSelector": .text($0)] } ?? [:])
    }

    private let client = IosHelperClient(serial: nil)

    @Test func aDomNodeRefRoutesToItsSelectorChain() {
        let snap = snapshot([domNode("r5", selector: chain)])
        #expect(client.webChain(forRef: "r5", in: snap) == chain)
    }

    @Test func aNativeRefDoesNot() {
        // The UIKit path is still the right one for a real field, and sending it
        // down the page path would fail on an app with no web view at all.
        let native = Node(ref: "r5", kind: .view, typeName: "UITextField",
                          frame: Rect(x: 0, y: 0, width: 10, height: 10))
        #expect(client.webChain(forRef: "r5", in: snapshot([native])) == nil)
    }

    @Test func aDomNodeWithNoChainFallsBackRatherThanSendingNothing() {
        // Absent is absent: without a chain there is nothing for the page path to
        // resolve, so the UIKit path (which at least reports why it cannot type)
        // must still run.
        #expect(client.webChain(forRef: "r5", in: snapshot([domNode("r5", selector: nil)])) == nil)
    }

    @Test func anUnknownRefIsNotRouted() {
        #expect(client.webChain(forRef: "r99", in: snapshot([domNode("r5", selector: chain)])) == nil)
    }
}
