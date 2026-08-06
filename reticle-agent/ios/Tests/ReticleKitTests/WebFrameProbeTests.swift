import XCTest
import WebKit
import ReticleProtocol
@testable import ReticleKit

/// The per-frame reader: the path into a frame whose document the page itself may not
/// read, which is what a third-party payment or bank widget is.
///
/// Everything here needs a real WKWebView doing a real load in a real window, which is
/// why it lives in the simulator suite rather than under `swift test`. The frame is
/// `sandbox="allow-scripts"` — an opaque origin, so `contentDocument` is refused
/// exactly as it would be for another host, while the probe inside it can still run.
/// That makes the whole mechanism exercisable offline.
@MainActor
final class WebFrameProbeTests: XCTestCase {

    private static let sealedFrameHtml = """
    <!doctype html>
    <html><body style="margin:0">
      <iframe id="sealed" sandbox="allow-scripts"
        style="width:300px;height:120px;border:0"
        srcdoc="<button id='inner' style='width:200px;height:60px'>Inside sealed frame</button>"></iframe>
    </body></html>
    """

    private func makeWebView(installProbeFirst: Bool) -> (UIWindow, WKWebView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 300),
                                configuration: WKWebViewConfiguration())
        window.addSubview(webView)
        // The mechanism's real limit, made a test parameter: a user script applies only
        // to documents loaded AFTER it is installed.
        if installProbeFirst { WebFrameProbe.install(on: webView) }
        webView.loadHTMLString(Self.sealedFrameHtml, baseURL: URL(string: "https://reticle.test/sealed"))
        waitUntilLoaded(webView)
        window.layoutIfNeeded()
        return (window, webView)
    }

    /// Spins the main run loop until the page and its frame have laid out. Polling the
    /// document beats the navigation delegate here: the frame's own load completes
    /// after the main document's, and it is the frame we are waiting for.
    private func waitUntilLoaded(_ webView: WKWebView) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            var ready = false
            let hop = expectation(description: "readyState")
            webView.evaluateJavaScript("document.readyState === 'complete' && document.querySelectorAll('iframe').length") { value, _ in
                ready = ((value as? NSNumber)?.intValue ?? 0) > 0
                hop.fulfill()
            }
            wait(for: [hop], timeout: 5)
            if ready { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        // One more turn for the frame's own document, which loads after its parent's.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    /// Runs the DOM capture the way the agent does: off the main thread, while the main
    /// run loop keeps turning so the bridge's main-queue hops can complete.
    private func capture(_ webView: WKWebView) -> Snapshot {
        let base = Snapshot(
            capturedAtMillis: 0,
            platform: "ios",
            screen: ScreenInfo(size: Size(width: 390, height: 844), density: 3.0),
            rootRef: "r0",
            nodes: [
                "r0": Node(
                    ref: "r0",
                    kind: .view,
                    typeName: "WKWebView",
                    role: "webView",
                    frame: Rect(x: 0, y: 0, width: 390, height: 300)
                ),
            ]
        )
        let pending = [WebViewBridge.Pending(
            webView: webView,
            parentRef: "r0",
            frame: Rect(x: 0, y: 0, width: 390, height: 300)
        )]
        let box = SnapshotBox()
        let done = expectation(description: "dom capture")
        DispatchQueue.global().async {
            var snapshot = base
            WebViewBridge.captureInto(&snapshot, pending: pending, nextRef: 1)
            box.value = snapshot
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        return box.value ?? base
    }

    private final class SnapshotBox: @unchecked Sendable {
        var value: Snapshot?
    }

    private func nodes(_ snapshot: Snapshot) -> [Node] { Array(snapshot.nodes.values) }

    private func node(_ snapshot: Snapshot, domId: String) -> Node? {
        nodes(snapshot).first { $0.domId() == domId }
    }

    // MARK: -

    func testASealedFrameIsReadInItsOwnContextWhenTheProbeWasThereFirst() throws {
        let (window, webView) = makeWebView(installProbeFirst: true)
        defer { window.isHidden = true }
        let snapshot = capture(webView)

        let frame = try XCTUnwrap(node(snapshot, domId: "sealed"), "the frame element itself must be captured")
        let inner = try XCTUnwrap(
            node(snapshot, domId: "inner"),
            "a sandbox-sealed frame's content must be read in the frame's own context"
        )
        // The wall is gone, so the markers that say "you cannot get in" must be too:
        // leaving them would tell a caller coordinates are the only way while a
        // selector now resolves, and `ScreenCoverage` reads the same fields.
        XCTAssertNil(frame.domFrameOpaque(), "a frame that WAS read must not still claim to be a wall")
        XCTAssertFalse(frame.domCrossOriginFrame())
        XCTAssertNil(frame.domFrameProbe())

        // The chained selector is the handle an agent acts through, and the geometry
        // must land inside the frame — the fold comes from the same traversal script as
        // the same-origin path, and this is what proves it was applied.
        XCTAssertEqual(inner.domCssSelector(), "#sealed >>> #inner")
        let f = try XCTUnwrap(frame.frame)
        let i = try XCTUnwrap(inner.frame)
        XCTAssertGreaterThanOrEqual(i.x, f.x - 1)
        XCTAssertGreaterThanOrEqual(i.y, f.y - 1)
        XCTAssertLessThanOrEqual(i.x + i.width, f.x + f.width + 1)
        XCTAssertLessThanOrEqual(i.y + i.height, f.y + f.height + 1)
    }

    func testAFrameLoadedBeforeTheProbeExistedSaysSoInsteadOfLookingEmpty() throws {
        let (window, webView) = makeWebView(installProbeFirst: false)
        defer { window.isHidden = true }
        let snapshot = capture(webView)

        let frame = try XCTUnwrap(node(snapshot, domId: "sealed"))
        // Both facts, separately: the page sealed the frame, AND the one mechanism that
        // could cross that never got a turn. Collapsing them would leave a caller
        // unable to tell "never readable" from "readable after this page navigates".
        XCTAssertEqual(frame.domFrameOpaque(), "sandboxed")
        XCTAssertEqual(frame.domFrameProbe(), "needs-reload")
        XCTAssertNil(node(snapshot, domId: "inner"), "no probe answered, so nothing inside may be claimed")
    }

    func testActivationIsRoutedIntoTheFrameThatOwnsTheChain() throws {
        let (window, webView) = makeWebView(installProbeFirst: true)
        defer { window.isHidden = true }
        // The capture is what teaches the registry which chain reaches which frame, so
        // activation depends on it having happened — same as the real command sequence.
        _ = capture(webView)

        let box = ActivationBox()
        let done = expectation(description: "activate")
        let pending = [WebViewBridge.Pending(
            webView: webView,
            parentRef: "r0",
            frame: Rect(x: 0, y: 0, width: 390, height: 300)
        )]
        DispatchQueue.global().async {
            box.value = WebActivation.activate(selectorChain: "#sealed >>> #inner", pending: pending)
            done.fulfill()
        }
        wait(for: [done], timeout: 20)

        let result = try XCTUnwrap(box.value)
        XCTAssertTrue(result.activated, "activation into a sealed frame failed: \(result.message ?? "-")")
        XCTAssertEqual(result.via, "domDispatch:frame")
    }

    private final class ActivationBox: @unchecked Sendable {
        var value: ActivationResult?
    }
}
