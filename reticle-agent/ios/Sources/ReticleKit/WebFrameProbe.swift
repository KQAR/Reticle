import Foundation
#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
import ObjectiveC

/// Per-frame access to a `WKWebView`'s frames — **including the ones the page itself
/// may not read**.
///
/// `evaluateJavaScript` runs in the main frame, so everything the DOM bridge knew came
/// from a document browser policy lets the top page read. A cross-origin (or
/// `sandbox`-sealed) frame was therefore a wall: no nodes, no selectors, and on a real
/// device not even a fallback, since the only input path there is in-process
/// activation, which resolves selectors *in the page*. A third-party payment or bank
/// widget is exactly that shape.
///
/// WebKit has the seam Playwright gets from the browser protocol:
/// `evaluateJavaScript(_:in:contentWorld:)` takes a `WKFrameInfo` and runs in THAT
/// frame's context, cross-origin included. What it has no API for is *enumerating*
/// frames — a `WKFrameInfo` only ever arrives attached to a message from a frame. So:
///
///  1. A `WKUserScript` with `forMainFrameOnly: false` puts a probe in every frame, in
///     an isolated content world (invisible to the page, and exempt from its CSP).
///  2. The host asks the main frame to `postMessage` an id to each `window.frames[i]`
///     — allowed across origins — and each probe passes ids down to its own children.
///     A frame's id is its index path: the one identity a frame has that survives an
///     origin nobody may read.
///  3. Each probe answers over a script-message handler, and the message carries the
///     `WKFrameInfo` this whole dance exists to obtain.
///
/// Two honest limits, both reported rather than hidden. A user script only applies to
/// documents loaded AFTER it is installed, so a frame already on screen at the first
/// capture answers nothing until it navigates — `iframe:probe-needs-reload`; Reticle
/// does not reload the app's page to fix that, since that is the app's state, not
/// ours. And a frame with scripting disabled (`sandbox` without `allow-scripts`) can
/// run no probe at all, ever.
enum WebFrameProbe {

    /// An isolated world: the probe's globals are invisible to the page, page globals
    /// cannot spoof the probe, and an injected script is exempt from the page's CSP.
    /// The DOM is shared, which is the part that matters.
    ///
    /// Built lazily on the main queue and cached, because `WKContentWorld.world(name:)`
    /// is main-actor isolated and every use of the world is already inside a main-queue
    /// hop. MUST be called on the main queue.
    private nonisolated(unsafe) static var cachedWorld: WKContentWorld?

    static func world() -> WKContentWorld {
        if let cachedWorld { return cachedWorld }
        let built = MainActor.assumeIsolated { WKContentWorld.world(name: "reticle-frames") }
        cachedWorld = built
        return built
    }

    private static let handlerName = "reticleFrames"

    /// How long a capture waits for probes to answer. Delivery is a main-queue hop per
    /// frame, not a network round trip.
    private static let handshakeWait: TimeInterval = 0.12

    /// Per-frame evaluation budget. Deliberately shorter than the main-frame read:
    /// this is paid once PER FRAME, and a screen with a widget farm must not turn one
    /// capture into several seconds.
    static let frameTimeout: TimeInterval = 0.5

    /// At most this many frames are read per capture, at most this deep. A page can
    /// nest frames without limit; a capture cannot. What the cap drops says so
    /// (`iframe:probe-budget`) instead of being silently skipped.
    static let frameBudget = 6
    static let depthBudget = 4

    /// One frame we can talk to: the handle to evaluate in, plus the selector chain
    /// that reaches it — which is what lets `act activate` route a chain into a frame
    /// the page cannot resolve through.
    struct Frame {
        let info: WKFrameInfo
        var chainPrefix: String
    }

    // MARK: - Registry

    /// The frames of ONE web view, keyed by index path.
    ///
    /// Attached to the web view as an associated object rather than held in a global
    /// table keyed by object identity: the table would outlive the view and an
    /// identity can be reused by a later allocation, which is a stale `WKFrameInfo`
    /// handed to the wrong page. This dies with the view it describes.
    /// Keeps `NSLock` rather than `Mutex`: the values are `WKFrameInfo` handles,
    /// which are not Sendable, and `Mutex.withLock` cannot hand a non-Sendable
    /// value back out.
    final class FrameTable: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: Frame] = [:]

        func record(path: String, info: WKFrameInfo) {
            lock.lock()
            // A re-navigated frame answers again under the same path with a fresh
            // handle; the newest is the one still alive, so it wins. The chain prefix
            // is set by the capture that reads the frame, and survives the refresh.
            map[path] = Frame(info: info, chainPrefix: map[path]?.chainPrefix ?? "")
            lock.unlock()
        }

        func frame(_ path: String) -> Frame? {
            lock.lock()
            defer { lock.unlock() }
            return map[path]
        }

        func setChainPrefix(_ path: String, _ chainPrefix: String) {
            lock.lock()
            map[path]?.chainPrefix = chainPrefix
            lock.unlock()
        }

        /// Every frame with a known chain, longest chain first — the order that makes a
        /// prefix match pick the INNERMOST frame reaching a chain, not an ancestor.
        func withChains() -> [Frame] {
            lock.lock()
            defer { lock.unlock() }
            return map.values
                .filter { !$0.chainPrefix.isEmpty }
                .sorted { $0.chainPrefix.count > $1.chainPrefix.count }
        }
    }

    private nonisolated(unsafe) static var tableKey: UInt8 = 0

    static func table(for webView: WKWebView) -> FrameTable {
        if let existing = objc_getAssociatedObject(webView, &tableKey) as? FrameTable { return existing }
        let table = FrameTable()
        objc_setAssociatedObject(webView, &tableKey, table, .OBJC_ASSOCIATION_RETAIN)
        return table
    }

    // MARK: - Installation

    private nonisolated(unsafe) static var installedKey: UInt8 = 0

    /// Idempotent per content controller (the same marker pattern `WebEvidence` uses).
    @MainActor
    static func install(on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        guard objc_getAssociatedObject(controller, &installedKey) == nil else { return }
        objc_setAssociatedObject(controller, &installedKey, true, .OBJC_ASSOCIATION_RETAIN)
        controller.add(Handler(webView: webView), contentWorld: world(), name: handlerName)
        controller.addUserScript(
            WKUserScript(
                source: probeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: world()
            )
        )
    }

    /// The probe, in every frame: it answers the handshake and passes ids down. It
    /// reads nothing about the page and changes nothing.
    private static let probeScript = """
    (function() {
      if (window.__reticleFrameProbe) return;
      window.__reticleFrameProbe = true;
      function answer(id) {
        try {
          webkit.messageHandlers.reticleFrames.postMessage({ id: id, url: String(location.href) });
        } catch (e) {}
      }
      function pass(id) {
        for (var i = 0; i < window.length; i++) {
          try {
            window.frames[i].postMessage({ __reticleFrameId: id + "/" + i }, "*");
          } catch (e) {}
        }
      }
      window.addEventListener("message", function(event) {
        var data = event.data;
        if (!data || typeof data !== "object" || typeof data.__reticleFrameId !== "string") return;
        answer(data.__reticleFrameId);
        pass(data.__reticleFrameId);
      });
    })();
    """

    /// Asks the main frame to hand each of its children an id. Self-contained on
    /// purpose: the main document may predate the probe, and a handshake that needed
    /// the probe there would then reach nothing at all.
    private static let handshakeScript = """
    (function() {
      for (var i = 0; i < window.length; i++) {
        try { window.frames[i].postMessage({ __reticleFrameId: String(i) }, "*"); } catch (e) {}
      }
      return window.length;
    })();
    """

    /// Runs the handshake and gives the probes a moment to answer. MUST run OFF the
    /// main thread, like every other bridge entry point.
    static func handshake(_ webView: WKWebView) {
        guard !Thread.isMainThread else { return }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            guard webView.window != nil else {
                done.signal()
                return
            }
            MainActor.assumeIsolated { install(on: webView) }
            unsafeBitCast(webView, to: FrameEvaluating.self).evaluateJavaScript(
                handshakeScript, inFrame: nil, inContentWorld: world()
            ) { _, _ in
                done.signal()
            }
        }
        guard done.wait(timeout: .now() + frameTimeout) == .success else { return }
        // The answers are one main-queue hop per frame; there is nothing to await but
        // time, and a capture that waited on a count would hang on a frame that is
        // sealed against scripting and can never reply.
        Thread.sleep(forTimeInterval: handshakeWait)
    }

    // MARK: - Per-frame evaluation

    /// Evaluates `script` inside one frame. nil when the frame is gone, the handle is
    /// stale, or the read outran its budget — each of which the caller reports rather
    /// than passing off as an empty frame.
    static func evaluate(_ script: String, in frame: WKFrameInfo, webView: WKWebView) -> String? {
        guard !Thread.isMainThread else { return nil }
        return WebEvaluate.onMain(in: webView, timeout: frameTimeout) { finish in
            unsafeBitCast(webView, to: FrameEvaluating.self).evaluateJavaScript(
                script, inFrame: frame, inContentWorld: world()
            ) { value, _ in
                finish(value as? String)
            }
        }
    }

    /// Receives one probe answer. The payload is almost beside the point — the
    /// `WKFrameInfo` on the message is what cannot be obtained any other way.
    private final class Handler: NSObject, WKScriptMessageHandler {
        private weak var webView: WKWebView?

        init(webView: WKWebView) {
            self.webView = webView
        }

        func userContentController(
            _ controller: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let webView,
                  let body = message.body as? [String: Any],
                  let path = body["id"] as? String,
                  !path.isEmpty else { return }
            WebFrameProbe.table(for: webView).record(path: path, info: message.frameInfo)
        }
    }
}

/// `WKWebView`'s frame-scoped evaluation, reached by SELECTOR rather than through the
/// Swift-refined signature.
///
/// Swift imports `evaluateJavaScript:inFrame:inContentWorld:completionHandler:` with a
/// `Result` completion, and that refinement lives in `libswiftWebKit.dylib` — a Swift
/// overlay that is **not present on older OS versions**. Measured in CI on an iOS 18.5
/// simulator: the whole bundle failed to load with `Library not loaded:
/// /usr/lib/swift/libswiftWebKit.dylib`. Since the agent's deployment floor is iOS 15,
/// using that signature would mean ReticleKit refusing to load on any pre-26 device —
/// a far worse outcome than the read it enables.
///
/// The underlying method is plain Objective-C and has been since iOS 14, so it is
/// declared here and sent to the view directly. `unsafeBitCast` is safe in the one way
/// that matters: the receiver IS a `WKWebView` and the selector IS the one it
/// implements; only the compile-time type is being bypassed.
@objc private protocol FrameEvaluating {
    @objc(evaluateJavaScript:inFrame:inContentWorld:completionHandler:)
    func evaluateJavaScript(
        _ javaScript: String,
        inFrame: WKFrameInfo?,
        inContentWorld: WKContentWorld,
        completionHandler: ((Any?, Error?) -> Void)?
    )
}
#endif
