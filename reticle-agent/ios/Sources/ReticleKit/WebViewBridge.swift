import Foundation
import ReticleProtocol
#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

/// Read-only WKWebView DOM bridge — the iOS port of the Android agent's
/// `WebViewBridge`.
///
/// The DOM is reached through `evaluateJavaScript`, which is asynchronous and
/// completes on the main thread. `SnapshotCapture` first records WKWebView
/// hosts during the normal main-thread view walk; this bridge then runs OFF the
/// main thread (the server's worker), posts the DOM read back to main, and
/// waits on a semaphore with a short timeout. On any failure the WebView stays
/// an opaque view node — the honest L0 fallback.
enum WebViewBridge {
    private static let timeout: TimeInterval = 0.75

    /// A WKWebView seen during the view walk. Crosses from the main thread to
    /// the server thread only as an opaque handle — it is touched again solely
    /// on the main queue inside `evaluate`.
    struct Pending: @unchecked Sendable {
        let webView: WKWebView
        let parentRef: String
        let frame: Rect
    }

    static func captureInto(_ snapshot: inout Snapshot, pending: [Pending], nextRef: Int) {
        guard !pending.isEmpty, !Thread.isMainThread else { return }
        var counter = nextRef
        for p in pending {
            guard let payload = evaluate(p.webView),
                  let data = payload.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let root = json["root"] as? [String: Any] else { continue }
            let fold = CoordinateFold(json: json, webViewFrame: p.frame)
            var domNodes: [String: Node] = [:]
            guard let rootRef = visit(root, parentRef: p.parentRef, fold: fold, nodes: &domNodes, counter: &counter) else { continue }
            snapshot.nodes.merge(domNodes) { existing, _ in existing }
            snapshot.nodes[p.parentRef]?.children.append(rootRef)
        }
    }

    private static func evaluate(_ webView: WKWebView) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        DispatchQueue.main.async {
            guard webView.window != nil else {
                semaphore.signal()
                return
            }
            webView.evaluateJavaScript(WebViewDomScript.script) { value, _ in
                box.value = value as? String
                semaphore.signal()
            }
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.value
    }

    /// The completion writes on main while the server thread waits, so plain
    /// mutable capture is race-free by construction; the class is only shared
    /// between those two points.
    private final class ResultBox: @unchecked Sendable {
        var value: String?
    }

    private static func visit(
        _ element: [String: Any],
        parentRef: String,
        fold: CoordinateFold,
        nodes: inout [String: Node],
        counter: inout Int
    ) -> String? {
        let ref = "r\(counter)"
        counter += 1

        var childRefs: [String] = []
        for case let child as [String: Any] in (element["children"] as? [Any]) ?? [] {
            if let childRef = visit(child, parentRef: ref, fold: fold, nodes: &nodes, counter: &counter) {
                childRefs.append(childRef)
            }
        }

        let tag = str(element["tag"])?.lowercased() ?? ""
        let role = str(element["role"]) ?? (tag.isEmpty ? "dom" : tag)
        let disabled = bool(element["disabled"])
        let frame = fold.rect(for: element)

        nodes[ref] = Node(
            ref: ref,
            parentRef: parentRef,
            kind: .domNode,
            typeName: "DOMElement",
            role: role,
            contentDescription: str(element["name"]),
            text: str(element["text"]),
            testId: str(element["testId"]),
            frame: frame,
            isVisible: frame.width > 0 && frame.height > 0,
            isEnabled: !disabled,
            isInteractive: !disabled && bool(element["interactive"]),
            custom: metadata(for: element, tag: tag, fold: fold),
            children: childRefs
        )
        return ref
    }

    private static func metadata(for element: [String: Any], tag: String, fold: CoordinateFold) -> [String: MetadataValue] {
        var map: [String: MetadataValue] = [:]
        func putText(_ key: String, _ elementKey: String) {
            if let v = str(element[elementKey]) { map[key] = .text(v) }
        }
        func putInteger(_ key: String, _ elementKey: String) {
            if let v = element[elementKey] as? NSNumber { map[key] = .integer(v.int64Value) }
        }
        func putBool(_ key: String, _ elementKey: String) {
            if element[elementKey] != nil { map[key] = .bool(bool(element[elementKey])) }
        }
        putText("domTag", "tag")
        putText("domId", "id")
        putText("domClass", "className")
        putText("domCssSelector", "selector")
        putText("domHref", "href")
        putText("domSrc", "src")
        putText("domSrcset", "srcset")
        putText("domSizes", "sizes")
        if tag == "img" {
            putText("domImageCurrentSrc", "imageCurrentSrc")
            putInteger("domImageNaturalWidth", "imageNaturalWidth")
            putInteger("domImageNaturalHeight", "imageNaturalHeight")
            putBool("domImageComplete", "imageComplete")
        }
        putText("domInputType", "inputType")
        putText("domMarginTop", "marginTop")
        putText("domMarginRight", "marginRight")
        putText("domMarginBottom", "marginBottom")
        putText("domMarginLeft", "marginLeft")
        let styleKeys = [
            ("domStyleDisplay", "styleDisplay"), ("domStyleVisibility", "styleVisibility"),
            ("domStyleOpacity", "styleOpacity"), ("domStylePosition", "stylePosition"),
            ("domStyleZIndex", "styleZIndex"), ("domStyleOverflowX", "styleOverflowX"),
            ("domStyleOverflowY", "styleOverflowY"), ("domStyleColor", "styleColor"),
            ("domStyleBackgroundColor", "styleBackgroundColor"), ("domStyleBackgroundImage", "styleBackgroundImage"),
            ("domStyleFontSize", "styleFontSize"), ("domStyleFontWeight", "styleFontWeight"),
            ("domStyleFontFamily", "styleFontFamily"), ("domStyleLineHeight", "styleLineHeight"),
            ("domStyleTextAlign", "styleTextAlign"), ("domStylePaddingTop", "stylePaddingTop"),
            ("domStylePaddingRight", "stylePaddingRight"), ("domStylePaddingBottom", "stylePaddingBottom"),
            ("domStylePaddingLeft", "stylePaddingLeft"), ("domStyleBorderTopWidth", "styleBorderTopWidth"),
            ("domStyleBorderRightWidth", "styleBorderRightWidth"), ("domStyleBorderBottomWidth", "styleBorderBottomWidth"),
            ("domStyleBorderLeftWidth", "styleBorderLeftWidth"), ("domStyleBorderRadius", "styleBorderRadius"),
            ("domStyleTransform", "styleTransform"), ("domStylePointerEvents", "stylePointerEvents"),
        ]
        for (metadataKey, elementKey) in styleKeys {
            putText(metadataKey, elementKey)
        }
        map["domScaleX"] = .real(fold.scaleX)
        map["domScaleY"] = .real(fold.scaleY)
        return map
    }

    private static func str(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bool(_ value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private static func double(_ value: Any?) -> Double {
        (value as? NSNumber)?.doubleValue ?? 0
    }

    /// Page (CSS) coordinates -> screen points. WKWebView viewport units are
    /// already points, so the scale is normally 1.0 and only corrects zoomed /
    /// scaled viewports (Android uses density here; iOS has no px/dp split).
    private struct CoordinateFold {
        let webViewFrame: Rect
        let scaleX: Double
        let scaleY: Double
        let scrollX: Double
        let scrollY: Double

        init(json: [String: Any], webViewFrame: Rect) {
            self.webViewFrame = webViewFrame
            let viewportWidth = WebViewBridge.double(json["viewportWidth"])
            let viewportHeight = WebViewBridge.double(json["viewportHeight"])
            scaleX = viewportWidth > 0 ? webViewFrame.width / viewportWidth : 1.0
            scaleY = viewportHeight > 0 ? webViewFrame.height / viewportHeight : 1.0
            scrollX = WebViewBridge.double(json["scrollX"])
            scrollY = WebViewBridge.double(json["scrollY"])
        }

        func rect(for element: [String: Any]) -> Rect {
            let left = WebViewBridge.double(element["left"]) - scrollX
            let top = WebViewBridge.double(element["top"]) - scrollY
            return Rect(
                x: webViewFrame.x + left * scaleX,
                y: webViewFrame.y + top * scaleY,
                width: WebViewBridge.double(element["width"]) * scaleX,
                height: WebViewBridge.double(element["height"]) * scaleY
            )
        }
    }
}
#endif
