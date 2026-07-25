import Foundation
import ReticleProtocol
#if canImport(UIKit)
import UIKit
#if canImport(WebKit)
import WebKit
#endif

/// Walks the live UIKit hierarchy into a `Snapshot` — the iOS analogue of the
/// Android `SnapshotCapture`. Rooted at a synthetic application node, then each
/// `UIWindowScene` window (bottom-to-top by level), then the `UIView` tree, with
/// SwiftUI content merged as `axElement` nodes via the accessibility bridge.
/// Refs are sequential (`r0`, `r1`, …), stable across an identical walk, so a ref
/// re-resolves to the same view for mutation.
@MainActor
struct SnapshotCapture {
    final class Builder {
        var nextRef = 0
        var nodes: [String: Node] = [:]
        var index: [String: UIView] = [:]
        /// ref -> accessibility element, for axElement nodes (SwiftUI content),
        /// so activation can target the element itself.
        var axIndex: [String: NSObject] = [:]
        #if canImport(WebKit)
        /// WKWebViews seen during the walk; their DOM is folded in afterwards,
        /// off the main thread (see `WebViewBridge`).
        var pendingWebViews: [WebViewBridge.Pending] = []
        #endif

        func makeRef() -> String {
            let r = "r\(nextRef)"
            nextRef += 1
            return r
        }
    }

    func capture() throws -> Snapshot {
        captureWithIndex().0
    }

    /// Capture plus a ref -> UIView index, for the mutation engine to re-resolve a
    /// ref to a live view.
    func captureWithIndex() -> (Snapshot, [String: UIView]) {
        let (snapshot, index, _) = captureWithIndexes()
        return (snapshot, index)
    }

    /// Capture plus both live indexes: ref -> UIView for view nodes, and
    /// ref -> accessibility element for axElement nodes.
    func captureWithIndexes() -> (Snapshot, [String: UIView], [String: NSObject]) {
        let (snapshot, b) = captureCore()
        return (snapshot, b.index, b.axIndex)
    }

    #if canImport(WebKit)
    /// What the server transport needs: the snapshot, the WKWebViews whose DOM
    /// still has to be folded in (off-main), and the next free ref for those
    /// dom nodes. `@unchecked Sendable`: the web view handles cross threads
    /// opaquely and are only dereferenced back on the main queue.
    struct TransportCapture: @unchecked Sendable {
        let snapshot: Snapshot
        let pendingWebViews: [WebViewBridge.Pending]
        let nextRef: Int
    }

    func captureForTransport() -> TransportCapture {
        let (snapshot, b) = captureCore()
        return TransportCapture(snapshot: snapshot, pendingWebViews: b.pendingWebViews, nextRef: b.nextRef)
    }
    #endif

    private func captureCore() -> (Snapshot, Builder) {
        let b = Builder()
        let appRef = b.makeRef()

        var childRefs: [String] = []
        for window in orderedWindows() {
            childRefs.append(captureView(window, parentRef: appRef, builder: b))
        }
        // App-authored probe nodes as synthetic children of the application node.
        for probe in ReticleRuntime.shared.registeredProbes() {
            childRefs.append(captureProbe(probe, parentRef: appRef, builder: b))
        }

        b.nodes[appRef] = Node(
            ref: appRef,
            kind: .application,
            typeName: "UIApplication",
            role: "application",
            children: childRefs
        )

        let snapshot = Snapshot(
            capturedAtMillis: nowMillis(),
            platform: "ios",
            screen: screenInfo(),
            rootRef: appRef,
            nodes: b.nodes
        )
        return (snapshot, b)
    }

    // MARK: - Windows / screen

    private func orderedWindows() -> [UIWindow] {
        var windows: [UIWindow] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            windows.append(contentsOf: windowScene.windows)
        }
        return windows.sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
    }

    private func screenInfo() -> ScreenInfo {
        let screen = orderedWindows().first?.screen ?? UIScreen.main
        let bounds = screen.bounds
        let style: String
        switch screen.traitCollection.userInterfaceStyle {
        case .dark: style = "dark"
        case .light: style = "light"
        default: style = "light"
        }
        return ScreenInfo(
            size: Size(width: Double(bounds.width), height: Double(bounds.height)),
            density: Double(screen.scale),
            interfaceStyle: style,
            keyboard: KeyboardMonitor.shared.status(),
            // A system alert (permission, biometric) is presented by another
            // process, so it appears in no window of this app: the tree looks
            // ordinary while input goes elsewhere. `applicationState` is the fact
            // iOS does expose — `.active` means this app still receives input.
            windowFocused: UIApplication.shared.applicationState == .active
        )
    }

    // MARK: - View capture

    private func captureView(_ view: UIView, parentRef: String, builder b: Builder, parentVisible: Bool = true) -> String {
        let ref = b.makeRef()
        b.index[ref] = view

        let effectiveVisible = parentVisible && !view.isHidden && view.alpha > 0.01
            && view.bounds.width > 0 && view.bounds.height > 0

        var children: [String] = []
        // SwiftUI hosting surface: merge accessibility-derived axElement nodes.
        let hostingEvidence = SwiftUISupport.hostingEvidence(for: view)
        if !hostingEvidence.isEmpty {
            children.append(contentsOf: captureSwiftUIElements(of: view, parentRef: ref, builder: b))
        }
        for sub in view.subviews {
            children.append(captureView(sub, parentRef: ref, builder: b, parentVisible: effectiveVisible))
        }

        let testId = view.accessibilityIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        var custom = scalarProperties(view)
        // SwiftUI evidence, if this is a hosting surface.
        if !hostingEvidence.isEmpty {
            custom["swiftUIHostingEvidence"] = .text(hostingEvidence.joined(separator: ","))
            custom.merge(SwiftUISupport.reflectState(of: view)) { _, new in new }
        }
        // App-attached metadata by testId.
        if let testId {
            custom.merge(ReticleRuntime.shared.metadata(for: testId)) { _, new in new }
        }

        // Sub-node interaction evidence (link runs, virtual a11y elements,
        // re-colored runs, text markers, char grid).
        let probed = RegionProbe.probe(view, isSwiftUIHost: !hostingEvidence.isEmpty)
        // A Lottie bakes its whole UI into one layer; recover its text layers as
        // sub-regions so they stay targetable.
        let lottieRegions = LottieBridge.regions(for: view, screenFrame: screenFrame(view))

        #if canImport(WebKit)
        // A WKWebView stays an opaque view node here; its DOM is folded in as
        // domNode children afterwards, off the main thread.
        if let webView = view as? WKWebView, let webFrame = screenFrame(view) {
            b.pendingWebViews.append(WebViewBridge.Pending(webView: webView, parentRef: ref, frame: webFrame))
        }
        #endif

        b.nodes[ref] = Node(
            ref: ref,
            parentRef: parentRef,
            // A UIWindow must be `.window`, not `.view`. `CompactObservation`
            // computes occlusion by walking the application node's WINDOW children
            // in stacking order, so while every window was typed `.view` the
            // window-vs-window path could not fire on iOS at all — an overlay
            // window covering the screen left the nodes underneath looking
            // perfectly tappable. Android has always reported this.
            //
            // The keyboard's host windows are the exception, and not a cosmetic
            // one: `UIRemoteKeyboardWindow` / `UITextEffectsWindow` span the WHOLE
            // screen even though the visible keys occupy the bottom strip, so
            // treating them as occluders marked every node on screen occluded —
            // including the ones above the keyboard (measured: the login screen's
            // status label and text field). Keyboard coverage has its own, exact
            // channel: `screen.keyboard` plus `occluded-by:keyboard`, which also
            // clears the moment `act hide-keyboard` runs, whereas the window can
            // linger.
            kind: (view is UIWindow && !SnapshotCapture.isKeyboardHostWindow(view)) ? .window : .view,
            typeName: NSStringFromClass(type(of: view)),
            role: role(for: view),
            resourceId: nil,
            contentDescription: view.accessibilityLabel.flatMap { $0.isEmpty ? nil : $0 },
            text: textContent(view),
            testId: testId,
            frame: screenFrame(view),
            isVisible: effectiveVisible,
            isEnabled: isEnabled(view),
            isInteractive: isInteractive(view),
            custom: custom,
            children: children,
            regions: probed.regions + lottieRegions,
            suspectedMultiRegion: probed.suspectedMultiRegion,
            charGrid: probed.charGrid,
            scroll: scrollInfo(view)
        )
        return ref
    }

    /// A scroll view's current scroll capability, or nil for anything else.
    ///
    /// This is the evidence behind the commonest E2E dead end: a `List` /
    /// `UICollectionView` keeps only its visible window realized, so a far-down
    /// row has no node at all — and without this flag that is indistinguishable
    /// from an element the app doesn't have. SwiftUI's `List` and `ScrollView` are
    /// `UIScrollView`s underneath, so one check covers both.
    /// Windows that merely HOST the system keyboard's remote content. Their frames
    /// are screen-sized, so they must not act as occluders — see the `kind:`
    /// comment above.
    static func isKeyboardHostWindow(_ view: UIView) -> Bool {
        var cls: AnyClass? = type(of: view)
        while let current = cls {
            let name = NSStringFromClass(current)
            if name.contains("RemoteKeyboardWindow") || name.contains("TextEffectsWindow") { return true }
            cls = class_getSuperclass(current)
        }
        return false
    }

    private func scrollInfo(_ view: UIView) -> ScrollInfo? {
        guard let scrollView = view as? UIScrollView else { return nil }
        let inset = scrollView.adjustedContentInset
        let offset = scrollView.contentOffset
        let content = scrollView.contentSize
        let bounds = scrollView.bounds.size
        let epsilon: CGFloat = 0.5
        let minY = -inset.top
        let maxY = max(content.height + inset.bottom - bounds.height, minY)
        let minX = -inset.left
        let maxX = max(content.width + inset.right - bounds.width, minX)
        let info = ScrollInfo(
            canScrollUp: offset.y > minY + epsilon,
            canScrollDown: offset.y < maxY - epsilon,
            canScrollLeft: offset.x > minX + epsilon,
            canScrollRight: offset.x < maxX - epsilon
        )
        return info.isScrollable ? info : nil
    }

    /// Some hosting surfaces expose content behind unlabeled AX *container*
    /// elements (`isAccessibilityElement == false`, no label, no identifier)
    /// instead of a flat array: a `NavigationView`'s `_UIHostingView` returns
    /// its elements flat, but a `TabView` page host (`TabHostingController`'s
    /// hosting view) wraps the whole page in one such container. A one-level
    /// read filtered that container out and silently dropped the entire page —
    /// the tab looked "empty" while its content was plainly on screen. Descend
    /// into containers instead; depth cap and a visited set guard against
    /// cyclic or degenerate AX graphs.
    private func flattenAXElements(
        _ objects: [NSObject],
        depth: Int = 0,
        visited: inout Set<ObjectIdentifier>
    ) -> [NSObject] {
        guard depth < 8 else { return [] }
        var out: [NSObject] = []
        for element in objects {
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            let isElement = (element.value(forKey: "isAccessibilityElement") as? Bool) ?? false
            let label = (element.accessibilityLabel ?? "")
            let identifier = SnapshotCapture.accessibilityIdentifier(of: element)
            if !isElement && identifier.isEmpty && label.isEmpty {
                let nested = SwiftUISupport.accessibilityElements(of: element)
                out.append(contentsOf: flattenAXElements(nested, depth: depth + 1, visited: &visited))
            } else {
                out.append(element)
            }
        }
        return out
    }

    private func captureSwiftUIElements(of host: UIView, parentRef: String, builder b: Builder) -> [String] {
        var visited = Set<ObjectIdentifier>()
        let elements = flattenAXElements(SwiftUISupport.accessibilityElements(of: host), visited: &visited)
        var refs: [String] = []
        var seenSignatures = Set<String>()
        for element in elements {
            // Only synthesize elements that are genuinely accessibility elements.
            let isElement = (element.value(forKey: "isAccessibilityElement") as? Bool) ?? false
            let label = (element.accessibilityLabel ?? "")
            let identifier = SnapshotCapture.accessibilityIdentifier(of: element)
            let traits = element.accessibilityTraits
            let frame = element.accessibilityFrame
            let signature = "\(identifier)|\(traits.rawValue)|\(label)|\(frame.debugDescription)"
            if !isElement && identifier.isEmpty && label.isEmpty { continue }
            if !seenSignatures.insert(signature).inserted { continue }

            let ref = b.makeRef()
            b.axIndex[ref] = element
            let role = SwiftUISupport.role(for: traits)
            let testId = identifier.isEmpty ? nil : identifier
            let elementFrame = frame.width > 0 ? rect(frame) : nil
            // Links inside ONE SwiftUI Text are sub-regions of this element, not
            // child elements — recovered from its accessibility attributed label.
            let textRegions = SwiftUITextRegions.probe(element: element, screenFrame: elementFrame)
            b.nodes[ref] = Node(
                ref: ref,
                parentRef: parentRef,
                kind: .axElement,
                typeName: SwiftUISupport.typeName(for: role),
                role: role,
                contentDescription: label.isEmpty ? nil : label,
                text: label.isEmpty ? nil : label,
                testId: testId,
                frame: elementFrame,
                isEnabled: !traits.contains(.notEnabled),
                isInteractive: traits.contains(.button) || traits.contains(.link) || traits.contains(.adjustable),
                custom: ["observationBackend": .text("native-accessibility")],
                regions: textRegions.regions,
                charGrid: textRegions.charGrid
            )
            refs.append(ref)
        }
        return refs
    }

    private func captureProbe(_ probe: ReticleRuntime.ProbeSpec, parentRef: String, builder b: Builder) -> String {
        let ref = b.makeRef()
        b.nodes[ref] = Node(
            ref: ref,
            parentRef: parentRef,
            kind: .probe,
            typeName: "ReticleProbe",
            role: "probe",
            contentDescription: probe.label,
            text: probe.label,
            testId: probe.testId,
            frame: probe.frame,
            isInteractive: true,
            custom: probe.metadata
        )
        return ref
    }

    /// SwiftUI's private accessibility nodes respond to `accessibilityIdentifier`
    /// without declaring `UIAccessibilityIdentification` conformance, so a
    /// protocol cast comes back nil and would drop the identifier (observed on
    /// List rows). Ask via the selector instead.
    static func accessibilityIdentifier(of element: NSObject) -> String {
        if let conforming = element as? UIAccessibilityIdentification {
            return conforming.accessibilityIdentifier ?? ""
        }
        let sel = NSSelectorFromString("accessibilityIdentifier")
        guard element.responds(to: sel),
              let value = element.perform(sel)?.takeUnretainedValue() as? String else { return "" }
        return value
    }

    // MARK: - Node field helpers

    private func screenFrame(_ view: UIView) -> Rect? {
        guard let window = view.window else {
            return rect(view.frame)
        }
        let inWindow = view.convert(view.bounds, to: nil)
        let screenOrigin = window.frame.origin
        return Rect(
            x: Double(inWindow.origin.x + screenOrigin.x),
            y: Double(inWindow.origin.y + screenOrigin.y),
            width: Double(inWindow.size.width),
            height: Double(inWindow.size.height)
        )
    }

    private func rect(_ r: CGRect) -> Rect {
        Rect(x: Double(r.origin.x), y: Double(r.origin.y), width: Double(r.size.width), height: Double(r.size.height))
    }

    private func role(for view: UIView) -> String {
        switch view {
        case is UIButton: return "button"
        case is UISwitch: return "switch"
        case is UISlider: return "slider"
        case is UITextField, is UITextView: return "textField"
        case is UIImageView: return "image"
        case is UILabel: return "text"
        case is UIScrollView: return "scrollView"
        case is UIWindow: return "window"
        case is UIControl: return "control"
        default:
            return view.subviews.isEmpty ? "view" : "container"
        }
    }

    private func textContent(_ view: UIView) -> String? {
        switch view {
        case let label as UILabel:
            return label.text
        case let button as UIButton:
            return button.currentTitle
        case let field as UITextField:
            if field.isSecureTextEntry { return field.text.map { String(repeating: "•", count: $0.count) } }
            return field.text
        case let textView as UITextView:
            return textView.text
        default:
            return nil
        }
    }

    private func isEnabled(_ view: UIView) -> Bool {
        (view as? UIControl)?.isEnabled ?? true
    }

    private func isInteractive(_ view: UIView) -> Bool {
        guard view.isUserInteractionEnabled else { return false }
        if view is UIControl { return true }
        if let recognizers = view.gestureRecognizers, !recognizers.isEmpty { return true }
        let traits = view.accessibilityTraits
        return traits.contains(.button) || traits.contains(.link)
    }

    private func scalarProperties(_ view: UIView) -> [String: MetadataValue] {
        var out: [String: MetadataValue] = [:]
        out["alpha"] = .real(Double(view.alpha))
        if let bg = view.backgroundColor {
            out["backgroundColor"] = .text(hex(bg, in: view.traitCollection))
        }
        // tintColor is an implicitly-unwrapped optional and is genuinely nil for
        // some views — guard it, never force-unwrap.
        if let tint = view.tintColor {
            out["tintColor"] = .text(hex(tint, in: view.traitCollection))
        }
        if let label = view as? UILabel {
            out["textColor"] = .text(hex(label.textColor, in: view.traitCollection))
            out["textSize"] = .real(Double(label.font.pointSize))
        }
        return out
    }

    private func hex(_ color: UIColor, in traits: UITraitCollection) -> String {
        ColorHex.hex(color, in: traits)
    }
}
#endif
