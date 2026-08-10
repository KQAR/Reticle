import Foundation
import ReticleProtocol
#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

/// In-process typing into a DOM field inside a WKWebView — the domNode
/// counterpart of `TextInputEngine`, and the sibling of `WebActivation`.
///
/// It exists because the UIKit path cannot reach a web field on a real device:
/// text entry there needs a `UIKeyInput` responder, and `WKWebView` does not
/// publish one. See `WebTextInputScript` for why the page is the input surface
/// and why `execCommand` comes before assignment.
///
/// Threading mirrors `WebActivation`: MUST run off the main thread; each
/// evaluation is posted to main and awaited with a timeout.
enum WebTextInput {
    private static let timeout: TimeInterval = 0.75

    /// Tries the selector chain in each captured web view (top window first);
    /// the first web view whose document matches the chain decides the result.
    static func type(
        selectorChain: String,
        text: String,
        clear: Bool,
        submit: Bool,
        pending: [WebViewBridge.Pending]
    ) -> TypeTextResult {
        guard !Thread.isMainThread else {
            return TypeTextResult(typed: false, message: "web typing must not run on the main thread")
        }
        guard !pending.isEmpty else {
            return TypeTextResult(
                typed: false,
                message: "no WKWebView on screen to resolve --css \(selectorChain)")
        }
        guard let script = WebTextInputScript.script(
            forSelectorChain: selectorChain, text: text, clear: clear, submit: submit)
        else {
            return TypeTextResult(typed: false, message: "could not encode selector chain")
        }

        for p in pending.reversed() {
            if let verdict = attempt(script, in: p.webView, via: "domInsertText") { return verdict }
            // Same frame walk as activation: a chain can reach into a frame the
            // page itself cannot resolve through, which the capture read in that
            // frame's own context.
            for frame in WebFrameProbe.table(for: p.webView).withChains() {
                let boundary = frame.chainPrefix + " >>> "
                guard selectorChain.hasPrefix(boundary) else { continue }
                let inner = String(selectorChain.dropFirst(boundary.count))
                guard let innerScript = WebTextInputScript.script(
                    forSelectorChain: inner, text: text, clear: clear, submit: submit) else { continue }
                if let verdict = attempt(
                    innerScript, in: p.webView, frame: frame.info, via: "domInsertText:frame"
                ) { return verdict }
            }
        }
        return TypeTextResult(typed: false, message: "no dom element matched selector \(selectorChain)")
    }

    /// One attempt, in the main frame (`frame` nil) or inside one frame. nil means
    /// "this document did not match the chain" — the caller keeps looking; a
    /// non-nil verdict is final, typed or refused, and carries the reason.
    private static func attempt(
        _ script: String,
        in webView: WKWebView,
        frame: WKFrameInfo? = nil,
        via: String
    ) -> TypeTextResult? {
        let payload = frame.map { WebFrameProbe.evaluate(script, in: $0, webView: webView) }
            ?? evaluate(script, in: webView)
        guard let payload,
              let data = payload.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        guard (json["matched"] as? NSNumber)?.boolValue == true else { return nil }

        let tag = json["tag"] as? String
        let typeName = tag.map { "DOMElement<\($0)>" } ?? "DOMElement"
        guard (json["typed"] as? NSNumber)?.boolValue == true else {
            let reason = json["reason"] as? String ?? "unknown"
            return TypeTextResult(
                typed: false, typeName: typeName,
                message: "dom element matched but is not typable: \(reason)")
        }
        // The page's own route is named, because `assign` did NOT go through the
        // input pipeline a keypress uses — a caller judging fidelity needs to see
        // which one ran.
        let route = json["via"] as? String ?? "execCommand"
        return TypeTextResult(
            typed: true, typeName: typeName, via: "\(via):\(route)",
            before: json["before"] as? String, after: json["after"] as? String)
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
