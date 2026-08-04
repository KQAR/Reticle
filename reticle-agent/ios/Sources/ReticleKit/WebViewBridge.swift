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

    /// Marker for "the DOM could not be read from this WKWebView right now".
    static let domStatusKey = "domStatus"
    static let domStatusUnavailable = "unavailable"

    static func captureInto(_ snapshot: inout Snapshot, pending: [Pending], nextRef: Int) {
        guard !pending.isEmpty, !Thread.isMainThread else { return }
        var counter = nextRef
        for p in pending {
            guard let payload = evaluate(p.webView),
                  let data = payload.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let root = json["root"] as? [String: Any] else {
                markDomUnavailable(&snapshot, p.parentRef)
                continue
            }
            let fold = CoordinateFold(json: json, webViewFrame: p.frame)
            var domNodes: [String: Node] = [:]
            guard let rootRef = visit(root, parentRef: p.parentRef, fold: fold, nodes: &domNodes, counter: &counter) else {
                markDomUnavailable(&snapshot, p.parentRef)
                continue
            }
            snapshot.nodes.merge(domNodes) { existing, _ in existing }
            snapshot.nodes[p.parentRef]?.children.append(rootRef)
        }
    }

    /// Record the fact instead of leaving an absence to be interpreted. A DOM read
    /// fails for reasons an agent must be able to tell apart from "this web view
    /// has no content": an `alert()`/`confirm()` modal blocks the page's JS thread
    /// so `evaluateJavaScript` can never call back, JS may be off, or the read may
    /// have outrun its budget while the page animates. All look identical — an
    /// opaque node — unless the node carries the fact.
    private static func markDomUnavailable(_ snapshot: inout Snapshot, _ ref: String) {
        snapshot.nodes[ref]?.custom[domStatusKey] = .text(domStatusUnavailable)
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
        // Laid out entirely outside a clipping ancestor's box: on screen in the
        // document's coordinates, and unseeable. Treated as not visible, which is
        // the treatment every other invisible node already gets.
        let clipped = bool(element["clipped"])
        let frame = fold.rect(for: element)

        let domMetadata = metadata(for: element, tag: tag, fold: fold)
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
            isVisible: frame.width > 0 && frame.height > 0 && !clipped,
            isEnabled: !disabled,
            isInteractive: !disabled && bool(element["interactive"]),
            checked: checkedState(str(element["checked"])),
            expanded: expandedState(str(element["expanded"])),
            custom: domMetadata,
            // Computed CSS is the DOM's style channel — the same tagging the Android
            // bridge applies, so a WKWebView and an android.webkit.WebView answer
            // `ui style` alike. The values keep their own suffixes ("14px", "1.5")
            // and are NOT converted: a page's zoom and viewport scaling are not
            // observable from here, so a px->pt division would be arithmetic on an
            // assumption. The projection passes them through verbatim
            // (StyleUnit.opaque).
            styleChannels: domMetadata.keys
                .filter { $0.hasPrefix("domStyle") }
                .reduce(into: [String: StyleChannel]()) { $0[$1] = .computedStyle },
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
        // The semantic handles a component-framework form actually carries. A
        // page whose inputs set no id and no value projects several identical
        // `textField` lines without these; the placeholder is usually the only
        // thing that says which one is the email field.
        if bool(element["clipped"]) { map["domClipped"] = .bool(true) }
        if bool(element["crossOriginFrame"]) { map["domCrossOriginFrame"] = .bool(true) }
        putText("domHasPopup", "hasPopup")
        // Only where the pointer STARTS, and only as the weak signal it is: the
        // page said "clickable" and nothing declared a role.
        if bool(element["pointerOrigin"]) { map["domCursor"] = .text("pointer") }
        // Page-truth sibling positions — see the Kotlin twin: counting the captured
        // parent's children would answer a `:nth-of-type(n)` query with the n-th
        // VISIBLE sibling, which is a silently-wrong tap.
        putInteger("domNthOfType", "nthOfType")
        putInteger("domNthChild", "nthChild")
        putText("domPlaceholder", "placeholder")
        putText("domName", "formName")
        putText("domDescribedBy", "describedBy")
        if bool(element["invalid"]) { map["domInvalid"] = .bool(true) }
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

    /// The script reports a tri-state as a string so an absent third state stays
    /// absent on the wire (nil = not a checkable control). Anything unrecognised
    /// maps to nil for the same reason: a value nobody understands is not
    /// evidence that a box is unticked.
    private static func checkedState(_ raw: String?) -> CheckedState? {
        switch raw {
        case "true": return .on
        case "false": return .off
        case "mixed": return .mixed
        default: return nil
        }
    }

    /// `nil` when the element declares no `aria-expanded` at all — a different
    /// fact from "closed", and the one that says this is not a disclosure control.
    private static func expandedState(_ raw: String?) -> Bool? {
        switch raw {
        case "true": return true
        case "false": return false
        default: return nil
        }
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
