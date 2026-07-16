import Foundation
import ReticleProtocol
#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit
import ObjectiveC

/// Web evidence collection: installs the `WebEvidenceScript` hooks into every
/// observed WKWebView and drains their in-page ring buffers into the agent's
/// log stream (`/logs`), so web console output, uncaught JS errors, and
/// fetch/XHR timings surface as regular Reticle evidence.
///
/// Pull-based by design: hooks buffer in the page; the agent drains whenever it
/// observes the app (snapshot or logs read). Evidence therefore starts at the
/// FIRST observation of a page — earlier events are honestly absent, and a
/// navigation resets the page's buffer (a `WKUserScript` re-installs the hooks
/// at document start for every later navigation, so only the very first page
/// misses its pre-observation events).
///
/// Threading mirrors `WebViewBridge`: `install` hops to main (fire-and-forget);
/// `drain` MUST run off the main thread and awaits each JS round trip on a
/// semaphore with a timeout.
enum WebEvidence {
    private static let timeout: TimeInterval = 0.75
    /// Address-only key for the "user script already added" associated-object
    /// marker; only touched on the main thread.
    @MainActor private static var userScriptFlag: UInt8 = 0

    /// Install hooks in every pending web view: once per content controller as
    /// a document-start `WKUserScript` (future navigations), plus an immediate
    /// idempotent evaluation for the page that is already loaded.
    static func install(pending: [WebViewBridge.Pending]) {
        guard !pending.isEmpty else { return }
        MainThread.async {
            for p in pending {
                let controller = p.webView.configuration.userContentController
                if objc_getAssociatedObject(controller, &userScriptFlag) == nil {
                    objc_setAssociatedObject(controller, &userScriptFlag, true, .OBJC_ASSOCIATION_RETAIN)
                    controller.addUserScript(WKUserScript(
                        source: WebEvidenceScript.install,
                        injectionTime: .atDocumentStart,
                        forMainFrameOnly: true
                    ))
                }
                p.webView.evaluateJavaScript(WebEvidenceScript.install) { _, _ in }
            }
        }
    }

    /// Drain buffered web events from every pending web view into the runtime
    /// log ring. Call from the server thread only.
    static func drain(pending: [WebViewBridge.Pending]) {
        guard !pending.isEmpty, !Thread.isMainThread else { return }
        for p in pending {
            guard let payload = evaluate(WebEvidenceScript.drain, in: p.webView),
                  let data = payload.data(using: .utf8),
                  let events = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { continue }
            for event in events {
                appendEvent(event)
            }
        }
    }

    /// One call for the common flow: make sure hooks are installed, then drain
    /// what previous installs have buffered.
    static func installAndDrain(pending: [WebViewBridge.Pending]) {
        drain(pending: pending)
        install(pending: pending)
    }

    private static func appendEvent(_ event: [String: Any]) {
        let kind = event["kind"] as? String ?? "console"
        let text = event["text"] as? String
        let url = event["url"] as? String
        let method = event["method"] as? String
        let status = (event["status"] as? NSNumber)?.int64Value

        let message: String
        switch kind {
        case "network":
            let target = [method, url].compactMap { $0 }.joined(separator: " ")
            if let error = event["error"] as? String {
                message = "web_network: \(target) -> \(error)"
            } else {
                message = "web_network: \(target) -> \(status.map(String.init) ?? "?")"
            }
        case "jsError":
            message = "web_error: \(text ?? "unknown")"
        default:
            message = "web_console: \(text ?? "")"
        }

        var metadata: [String: MetadataValue] = ["source": .text("web"), "kind": .text(kind)]
        if let text { metadata["text"] = .text(text) }
        if let url { metadata["url"] = .text(url) }
        if let method { metadata["method"] = .text(method) }
        if let status { metadata["status"] = .integer(status) }
        if let api = event["api"] as? String { metadata["api"] = .text(api) }
        if let duration = (event["durationMs"] as? NSNumber)?.int64Value { metadata["durationMs"] = .integer(duration) }
        if let error = event["error"] as? String { metadata["error"] = .text(error) }
        if let ts = (event["ts"] as? NSNumber)?.int64Value { metadata["pageTimestampMillis"] = .integer(ts) }

        let level: String
        switch event["level"] as? String {
        case "error": level = "error"
        case "warn": level = "warn"
        case "debug": level = "debug"
        default: level = "info"
        }
        ReticleRuntime.shared.appendLog(level: level, message: message, metadata: metadata)
    }

    /// A lightweight main-thread scan for on-screen web views, so `/logs` can
    /// drain evidence without building a full snapshot. Only the `webView`
    /// handle matters here; parentRef/frame are placeholders.
    @MainActor
    static func scanPending() -> [WebViewBridge.Pending] {
        var out: [WebViewBridge.Pending] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                collectWebViews(window, into: &out)
            }
        }
        return out
    }

    @MainActor
    private static func collectWebViews(_ view: UIView, into out: inout [WebViewBridge.Pending]) {
        if let webView = view as? WKWebView {
            out.append(WebViewBridge.Pending(webView: webView, parentRef: "", frame: Rect(x: 0, y: 0, width: 0, height: 0)))
        }
        for sub in view.subviews {
            collectWebViews(sub, into: &out)
        }
    }

    private static func evaluate(_ script: String, in webView: WKWebView) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()
        DispatchQueue.main.async {
            guard webView.window != nil else {
                semaphore.signal()
                return
            }
            webView.evaluateJavaScript(script) { value, _ in
                box.value = value as? String
                semaphore.signal()
            }
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }

    /// Written on main while the server thread waits — race-free by construction.
    private final class Box: @unchecked Sendable {
        var value: String?
    }
}
#endif
