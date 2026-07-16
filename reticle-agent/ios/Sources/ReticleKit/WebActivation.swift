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
            guard let payload = evaluate(script, in: p.webView),
                  let data = payload.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let matched = (json["matched"] as? NSNumber)?.boolValue ?? false
            if !matched { continue }
            let activated = (json["activated"] as? NSNumber)?.boolValue ?? false
            if activated {
                return ActivationResult(
                    activated: true,
                    typeName: (json["tag"] as? String).map { "DOMElement<\($0)>" } ?? "DOMElement",
                    via: "domDispatch"
                )
            }
            let reason = json["reason"] as? String ?? "unknown"
            return ActivationResult(activated: false, message: "dom element matched but not actionable: \(reason)")
        }
        return ActivationResult(activated: false, message: "no dom element matched selector \(selectorChain)")
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
