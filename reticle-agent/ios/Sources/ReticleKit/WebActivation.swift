import Foundation
import ReticleProtocol
#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

/// In-process activation of a DOM element inside a WKWebView — the domNode
/// counterpart of `ActivationEngine`. Works wherever the agent runs (real
/// device included), independent of any HID surface.
///
/// Threading mirrors `WebViewBridge`: MUST run off the main thread; each
/// evaluation is posted to main and awaited on a semaphore with a timeout.
enum WebActivation {
    private static let timeout: TimeInterval = 0.75

    /// Tries the selector chain in each captured web view (top window first);
    /// the first web view whose document matches the chain decides the result.
    static func activate(selectorChain: String, pending: [WebViewBridge.Pending]) -> ActivationResult {
        guard !Thread.isMainThread else {
            return ActivationResult(activated: false, message: "web activation must not run on the main thread")
        }
        guard !pending.isEmpty else {
            return ActivationResult(activated: false, message: "no WKWebView on screen to resolve --css \(selectorChain)")
        }
        guard let script = WebActivationScript.script(forSelectorChain: selectorChain) else {
            return ActivationResult(activated: false, message: "could not encode selector chain")
        }

        for p in pending.reversed() {
            if let verdict = attempt(script, in: p.webView, via: "domDispatch") { return verdict }
            // The chain may reach into a frame the PAGE cannot resolve through: a
            // cross-origin or sandbox-sealed frame, whose content the capture read in
            // the frame's own context (`WebFrameProbe`). Resolving there means asking
            // that frame directly, with the part of the chain that is relative to it —
            // otherwise a control Reticle just reported would be unactionable on a
            // real device, where in-process activation is the ONLY input path.
            for frame in WebFrameProbe.table(for: p.webView).withChains() {
                let boundary = frame.chainPrefix + " >>> "
                guard selectorChain.hasPrefix(boundary) else { continue }
                let inner = String(selectorChain.dropFirst(boundary.count))
                guard let innerScript = WebActivationScript.script(forSelectorChain: inner) else { continue }
                if let verdict = attempt(
                    innerScript, in: p.webView, frame: frame.info, via: "domDispatch:frame"
                ) { return verdict }
            }
        }
        return ActivationResult(activated: false, message: "no dom element matched selector \(selectorChain)")
    }

    /// One activation attempt, in the main frame (`frame` nil) or inside one frame.
    /// nil means "this document did not match the chain" — the caller keeps looking;
    /// a non-nil verdict is final, matched or refused, and carries the reason.
    private static func attempt(
        _ script: String,
        in webView: WKWebView,
        frame: WKFrameInfo? = nil,
        via: String
    ) -> ActivationResult? {
        let payload = frame.map { WebFrameProbe.evaluate(script, in: $0, webView: webView) }
            ?? evaluate(script, in: webView)
        guard let payload,
              let data = payload.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard (json["matched"] as? NSNumber)?.boolValue == true else { return nil }
        if (json["activated"] as? NSNumber)?.boolValue == true {
            return ActivationResult(
                activated: true,
                typeName: (json["tag"] as? String).map { "DOMElement<\($0)>" } ?? "DOMElement",
                via: via
            )
        }
        let reason = json["reason"] as? String ?? "unknown"
        return ActivationResult(activated: false, message: "dom element matched but not actionable: \(reason)")
    }

    private static func evaluate(_ script: String, in webView: WKWebView) -> String? {
        WebEvaluate.script(script, in: webView, timeout: timeout)
    }
}
#endif
