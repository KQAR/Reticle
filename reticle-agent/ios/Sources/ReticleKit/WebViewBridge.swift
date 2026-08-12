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
                  var root = json["root"] as? [String: Any] else {
                markDomUnavailable(&snapshot, p.parentRef)
                continue
            }
            // Frames the page itself may not read are walked in their OWN context
            // (`WebFrameProbe`), then spliced in here. Only paid for on a screen that
            // has such a frame: the handshake and the per-frame reads are main-queue
            // round trips, and most pages have none.
            if hasOpaqueFrame(root) {
                WebFrameProbe.handshake(p.webView)
                var budget = WebFrameProbe.frameBudget
                root = spliceFrames(root, webView: p.webView, path: "", depth: 0, budget: &budget)
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
        WebEvaluate.script(WebViewDomScript.script, in: webView, timeout: timeout)
    }

    // MARK: - Frames the page may not read

    /// Is there a frame on this page whose document the page itself could not walk?
    /// Asked before anything else, because the per-frame path costs main-queue round
    /// trips and the overwhelming majority of pages have no such frame.
    private static func hasOpaqueFrame(_ node: [String: Any]) -> Bool {
        if str(node["frameOpaque"]) != nil { return true }
        for case let child as [String: Any] in (node["children"] as? [Any]) ?? [] {
            if hasOpaqueFrame(child) { return true }
        }
        return false
    }

    /// Walks each opaque frame IN ITS OWN CONTEXT and splices the result under the
    /// frame element, in the raw traversal JSON — before `visit`, so there is exactly
    /// one node-building path and the spliced nodes are indistinguishable from any
    /// other DOM node (which is the point: an agent should not have to know which
    /// mechanism read a control).
    ///
    /// The geometry is NOT recomputed here. The enclosing frame's fold is handed to
    /// the traversal script through `reticleFrameCtx`, so every line of frame geometry
    /// stays in `dom-traversal.js` — a second copy in Swift and a third in Kotlin is
    /// how one rect gets three answers.
    private static func spliceFrames(
        _ input: [String: Any],
        webView: WKWebView,
        path: String,
        depth: Int,
        budget: inout Int
    ) -> [String: Any] {
        var node = input
        // Siblings and descendants in the SAME document keep this document's path — a
        // path identifies a frame, not an element.
        if let children = node["children"] as? [Any] {
            node["children"] = children.map { child -> Any in
                guard let dict = child as? [String: Any] else { return child }
                return spliceFrames(dict, webView: webView, path: path, depth: depth, budget: &budget)
            }
        }
        guard str(node["frameOpaque"]) != nil else { return node }
        // Without an index there is no identity to key a frame by, so there is nothing
        // to look up: `contentWindow` itself was refused.
        guard let index = (node["frameIndex"] as? NSNumber)?.intValue, index >= 0 else {
            node["frameProbe"] = "no-handle"
            return node
        }
        guard depth < WebFrameProbe.depthBudget else {
            node["frameProbe"] = "depth-budget"
            return node
        }
        guard budget > 0 else {
            node["frameProbe"] = "budget"
            return node
        }
        let framePath = path.isEmpty ? "\(index)" : "\(path)/\(index)"
        let table = WebFrameProbe.table(for: webView)
        // No probe answered for this frame: it was loaded before the probe existed, or
        // it has no scripting at all. Reported, never guessed at — and NOT fixed by
        // reloading the app's page from here: that is the app's state, not ours.
        guard let frame = table.frame(framePath) else {
            node["frameProbe"] = "needs-reload"
            return node
        }
        let chain = str(node["selector"]) ?? ""
        guard let script = frameScript(for: node, chain: chain) else {
            node["frameProbe"] = "failed"
            return node
        }
        budget -= 1
        table.setChainPrefix(framePath, chain)
        guard let payload = WebFrameProbe.evaluate(script, in: frame.info, webView: webView),
              let data = payload.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var childRoot = json["root"] as? [String: Any] else {
            node["frameProbe"] = "failed"
            return node
        }
        // A frame we just read may itself hold frames it cannot read.
        childRoot = spliceFrames(childRoot, webView: webView, path: framePath, depth: depth + 1, budget: &budget)
        node["children"] = ((node["children"] as? [Any]) ?? []) + [childRoot]
        // The wall is no longer a wall. Leaving the marker would tell a caller that
        // coordinates are the only way in while selectors now resolve — and
        // `ScreenCoverage` reads the same fields to decide whether a region has any
        // selector over it at all.
        node["frameOpaque"] = ""
        node["crossOriginFrame"] = false
        node["framePierced"] = "per-frame"
        return node
    }

    /// The traversal script, prefixed with the fold and selector chain of the frame it
    /// is about to run in.
    private static func frameScript(for node: [String: Any], chain: String) -> String? {
        let scaleX = double(node["frameScaleX"])
        let scaleY = double(node["frameScaleY"])
        let ctx: [String: Any] = [
            // The frame's border is in the PARENT's pixels, so it takes the transform
            // factor (already folded into frameScale*) and not the frame's own
            // viewport factor, which applies only inside.
            "x": double(node["left"]) + double(node["frameClientLeft"]) * scaleX,
            "y": double(node["top"]) + double(node["frameClientTop"]) * scaleY,
            "sx": scaleX == 0 ? 1 : scaleX,
            "sy": scaleY == 0 ? 1 : scaleY,
            "approx": bool(node["frameSkewed"]),
            // The parent cannot read a foreign frame's viewport; the inside finishes
            // the scale from these.
            "contentWidth": double(node["frameClientWidth"]),
            "contentHeight": double(node["frameClientHeight"]),
        ]
        guard let ctxData = try? JSONSerialization.data(withJSONObject: ctx),
              let ctxJSON = String(data: ctxData, encoding: .utf8),
              let chainData = try? JSONSerialization.data(withJSONObject: [chain]),
              let chainJSON = String(data: chainData, encoding: .utf8) else { return nil }
        return """
        var reticleFrameCtx = \(ctxJSON);
        var reticleFramePrefix = \(chainJSON)[0];
        \(WebViewDomScript.script)
        """
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
            // `document.activeElement`, as the page reported it — see the Kotlin twin.
            isFocused: bool(element["focused"]),
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
            children: childRefs,
            // The DOM's own scroll port, published as the capability a native
            // container publishes — a pane (or a frame, which scrolls its own
            // document) that can still move now says so.
            scroll: scrollInfo(for: element)
        )
        return ref
    }

    /// The scroll numbers the traversal read from this element's scroll port, or nil
    /// when it has none. The rule lives in `DomScroll` (with a Kotlin twin), not
    /// here, so both platforms answer alike.
    private static func scrollInfo(for element: [String: Any]) -> ScrollInfo? {
        func metric(_ key: String) -> Double {
            (element[key] as? NSNumber)?.doubleValue ?? -1
        }
        return DomScroll.fromMetrics(
            scrollLeft: metric("scrollLeft"),
            scrollTop: metric("scrollTop"),
            scrollWidth: metric("scrollWidth"),
            scrollHeight: metric("scrollHeight"),
            clientWidth: metric("scrollClientWidth"),
            clientHeight: metric("scrollClientHeight")
        )
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
        // A frame's identity and the reason its subtree is empty, if it is. All of
        // these are readable across origins — policy withholds the document, not the
        // element — and they are what separates "still loading, retry" from "another
        // origin, use coordinates" from "the page sandboxed it, fix the page".
        putText("domFrameOpaque", "frameOpaque")
        putText("domFrameName", "frameName")
        putText("domFrameUrl", "frameUrl")
        putText("domFrameReadyState", "frameReadyState")
        putText("domFrameSandbox", "frameSandbox")
        putText("domFrameAllow", "frameAllow")
        putText("domFrameLoading", "frameLoading")
        // Why a frame that COULD have been read per-frame was not, and how one that
        // was got read. Both are about the mechanism, not the page, and both matter to
        // a caller: the first says whether anything would change on a retry, the
        // second that these nodes came from inside a wall.
        putText("domFrameProbe", "frameProbe")
        putText("domFramePierced", "framePierced")
        if let childFrames = element["frameChildCount"] as? NSNumber, childFrames.int64Value >= 0 {
            map["domFrameChildCount"] = .integer(childFrames.int64Value)
        }
        // A rotated or skewed frame in the chain: the rect is the axis-aligned hull
        // of the real box, so a tap at its centre can miss. Stated, not smoothed.
        if bool(element["geometryApprox"]) { map["domGeometryApprox"] = .bool(true) }
        // The numbers behind the `scroll:` capability, kept as evidence: "one flick
        // left" and "twenty screens left" are the same flag and different situations.
        for (metadataKey, elementKey) in [
            ("domScrollLeft", "scrollLeft"), ("domScrollTop", "scrollTop"),
            ("domScrollWidth", "scrollWidth"), ("domScrollHeight", "scrollHeight"),
            ("domScrollClientWidth", "scrollClientWidth"),
            ("domScrollClientHeight", "scrollClientHeight"),
        ] {
            if let value = element[elementKey] as? NSNumber, value.int64Value >= 0 {
                map[metadataKey] = .integer(value.int64Value)
            }
        }
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
        // Which accname rule produced the label — see the Kotlin twin.
        putText("domNameSource", "nameSource")
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

        init(json: [String: Any], webViewFrame: Rect) {
            self.webViewFrame = webViewFrame
            let viewportWidth = WebViewBridge.double(json["viewportWidth"])
            let viewportHeight = WebViewBridge.double(json["viewportHeight"])
            scaleX = viewportWidth > 0 ? webViewFrame.width / viewportWidth : 1.0
            scaleY = viewportHeight > 0 ? webViewFrame.height / viewportHeight : 1.0
        }

        /// The script reports VIEWPORT coordinates, so no scroll enters here — see
        /// the note on `left`/`top` in dom-traversal.js. It used to add the page
        /// scroll per element and subtract it once, from a read taken after the walk;
        /// a page that moved mid-walk folded to rects offset by the delta.
        func rect(for element: [String: Any]) -> Rect {
            let left = WebViewBridge.double(element["left"])
            let top = WebViewBridge.double(element["top"])
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
