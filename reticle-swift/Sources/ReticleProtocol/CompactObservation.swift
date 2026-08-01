import Foundation

/// Token-cheap summary: one line per interactive or labelled node. Mirrors
/// reticle-core's `CompactObservation`.
public struct CompactObservation: Codable, Sendable {
    public var capturedAtMillis: Int64
    public var screen: ScreenInfo
    public var items: [CompactItem]
    /// How many anonymous layers were folded into the named items above. Zero on a
    /// tree that had none; reported so a token-cheap projection never quietly
    /// claims to be the whole picture.
    public var collapsedWrappers: Int
    /// How many items past the projection cap were DROPPED, not just folded. Zero
    /// when everything fit. Like `collapsedWrappers`, this exists so the cap can
    /// never silently read as "that was the whole screen".
    public var truncatedItems: Int

    /// `CompactItem.occludedBy` value for the system keyboard (IME).
    public static let occluderKeyboard = "keyboard"

    // Hand-written coding, for the same reason `CompactItem` has it: reticle-core
    // omits a field equal to its default, so `collapsedWrappers` is absent from
    // every payload that folded nothing — and from every payload produced before
    // folding existed. Synthesised decoding would reject both.
    private enum CodingKeys: String, CodingKey {
        case capturedAtMillis, screen, items, collapsedWrappers, truncatedItems
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(capturedAtMillis, forKey: .capturedAtMillis)
        try c.encode(screen, forKey: .screen)
        try c.encode(items, forKey: .items)
        if collapsedWrappers != 0 { try c.encode(collapsedWrappers, forKey: .collapsedWrappers) }
        if truncatedItems != 0 { try c.encode(truncatedItems, forKey: .truncatedItems) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capturedAtMillis = try c.decode(Int64.self, forKey: .capturedAtMillis)
        screen = try c.decode(ScreenInfo.self, forKey: .screen)
        items = try c.decode([CompactItem].self, forKey: .items)
        collapsedWrappers = try c.decodeIfPresent(Int.self, forKey: .collapsedWrappers) ?? 0
        truncatedItems = try c.decodeIfPresent(Int.self, forKey: .truncatedItems) ?? 0
    }

    public init(capturedAtMillis: Int64, screen: ScreenInfo, items: [CompactItem],
                collapsedWrappers: Int = 0, truncatedItems: Int = 0) {
        self.capturedAtMillis = capturedAtMillis
        self.screen = screen
        self.items = items
        self.collapsedWrappers = collapsedWrappers
        self.truncatedItems = truncatedItems
    }

    /// Build from a snapshot, keeping interactive or labelled *visible* nodes.
    public static func from(_ snapshot: Snapshot, maxItems: Int = 200) -> CompactObservation {
        // Occlusion is judged at the item's tap point (frame center — where
        // selector-resolved taps land) against everything stacked above it:
        // higher z-order in-app windows (application children are the window
        // roots in stacking order) and the keyboard. The keyboard is another
        // process's window — never a node — so it comes from ScreenInfo.keyboard.
        let windowRefs = (snapshot.nodes[snapshot.rootRef]?.children ?? [])
            .filter { snapshot.nodes[$0]?.kind == .window }
        let windowOrder = Dictionary(uniqueKeysWithValues: windowRefs.enumerated().map { ($1, $0) })
        let keyboardFrame = (snapshot.screen.keyboard?.visible == true) ? snapshot.screen.keyboard?.frame : nil

        func occluderOf(_ node: Node, windowRef: String?) -> String? {
            guard let frame = node.frame else { return nil }
            let cx = frame.centerX
            let cy = frame.centerY
            // The keyboard layer sits above every app window, so it wins when
            // both it and a dialog cover the point.
            if keyboardFrame?.contains(cx, cy) == true { return occluderKeyboard }
            guard let windowRef, let index = windowOrder[windowRef] else { return nil }
            for i in (index + 1)..<windowRefs.count {
                guard let above = snapshot.nodes[windowRefs[i]], above.isVisible else { continue }
                if above.frame?.contains(cx, cy) == true { return above.ref }
            }
            return nil
        }

        /// How much of a wheel column is readable, or nil when this is not one.
        /// `selection-only` when the current value survives as a child node (an
        /// Android `NumberPicker`), `opaque` when the control publishes nothing at
        /// all. Either way its unselected values are pixels and the control must be
        /// driven with `swipe`. Kept identical to the Kotlin twin.
        func wheelMarker(_ node: Node) -> String? {
            guard node.suspectedWheel else { return nil }
            var seen = Set<String>()
            func hasTextInside(_ ref: String) -> Bool {
                guard let child = snapshot.nodes[ref], seen.insert(ref).inserted else { return false }
                // Blank counts as NO text, like the Kotlin twin's isNullOrBlank:
                // a cleared NumberPicker input holds " ", and `selection-only`
                // would send the agent to read a value that is whitespace.
                if ref != node.ref,
                   !(child.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return true
                }
                return child.children.contains(where: hasTextInside)
            }
            return hasTextInside(node.ref) ? "selection-only" : "opaque"
        }

        var items: [CompactItem] = []
        func visit(_ ref: String, _ windowRef: String?) {
            guard let node = snapshot.nodes[ref] else { return }
            let currentWindow = node.kind == .window ? node.ref : windowRef
            // Same targeting-signal test as the semantic tree, plus a visibility
            // filter: the compact view is for acting now, so a hidden-but-labelled
            // node is intentionally omitted here even though the semantic tree keeps it.
            if node.hasTargetingSignal() && node.isVisible {
                items.append(
                    CompactItem(
                        ref: node.ref,
                        role: node.role ?? node.typeName,
                        testId: node.testId,
                        resourceId: node.resourceId,
                        label: node.contentDescription ?? node.text,
                        frame: node.frame,
                        isEnabled: node.isEnabled,
                        isInteractive: node.isInteractive,
                        windowRef: currentWindow,
                        isFocused: node.isFocused,
                        occludedBy: occluderOf(node, windowRef: currentWindow),
                        scroll: node.scroll,
                        wheel: wheelMarker(node),
                        domUnavailable: node.domUnavailable(),
                        domKernelUnsupported: node.domKernelUnsupported(),
                        pixelsUnavailable: node.pixelsUnavailable(),
                        screencapBlank: node.screencapBlank()
                    )
                )
            }
            for c in node.children { visit(c, currentWindow) }
        }
        visit(snapshot.rootRef, nil)
        let folded = collapseWrappers(snapshot, items)
        let kept = Array(folded.items.prefix(maxItems))
        return CompactObservation(
            capturedAtMillis: snapshot.capturedAtMillis,
            screen: snapshot.screen,
            items: kept,
            collapsedWrappers: folded.collapsed,
            truncatedItems: folded.items.count - kept.count
        )
    }
}

/// The item list after folding, and how many anonymous layers went into it.
private struct Folded {
    let items: [CompactItem]
    let collapsed: Int
}

/// How much bigger than the node it wraps a layer may be and still be a wrapper.
private let wrapperAreaRatio = 2.0

/// Fold anonymous layers into the named node they sit on — the Swift twin of
/// reticle-core's `collapseWrappers`, which carries the full rationale.
///
/// Measured here: a `UIPickerView` row is three compact lines (the cell, the
/// label, the cell's content view), two of them anonymous rectangles at the same
/// place — 86 lines for a two-column wheel, 46 carrying nothing actionable. A
/// layer folds only when it has no identity of its own, a named item's tap point
/// falls inside it, it HUGS that item (at least as large, at most
/// `wrapperAreaRatio`x its area), the two are related, and it is neither a
/// window/application node nor the focused one. The survivor inherits
/// `isInteractive`, and nothing leaves the snapshot.
private func collapseWrappers(_ snapshot: Snapshot, _ items: [CompactItem]) -> Folded {
    func node(_ item: CompactItem) -> Node? { snapshot.nodes[item.ref] }
    func identified(_ item: CompactItem) -> Bool {
        guard let n = node(item) else { return true } // unknown node: never fold what we can't inspect
        return item.testId != nil || item.resourceId != nil || item.label != nil
            || item.scroll != nil || item.wheel != nil
            || !n.regions.isEmpty || n.charGrid != nil || n.suspectedMultiRegion
            || n.custom["domCssSelector"] != nil
    }
    func area(_ item: CompactItem) -> Double {
        guard let f = item.frame else { return 0 }
        return f.width * f.height
    }
    func related(_ a: CompactItem, _ b: CompactItem) -> Bool {
        guard let na = node(a), let nb = node(b) else { return false }
        if let pa = na.parentRef, pa == nb.parentRef { return true }
        func descends(_ from: Node, _ ancestorRef: String) -> Bool {
            var current = from.parentRef.flatMap { snapshot.nodes[$0] }
            var seen = Set<String>()
            while let c = current, seen.insert(c.ref).inserted {
                if c.ref == ancestorRef { return true }
                current = c.parentRef.flatMap { snapshot.nodes[$0] }
            }
            return false
        }
        return descends(na, nb.ref) || descends(nb, na.ref)
    }

    let named = items.filter { identified($0) && area($0) > 0 }
    if named.isEmpty { return Folded(items: items, collapsed: 0) }
    var absorbedInteractive = Set<String>()
    var dropped = Set<String>()
    for item in items {
        guard let n = node(item) else { continue }
        if n.kind == .window || n.kind == .application { continue }
        if n.isFocused || identified(item) { continue }
        guard let frame = item.frame else { continue }
        let selfArea = area(item)
        if selfArea <= 0 { continue }
        let anchor = named.first { other in
            guard let o = other.frame else { return false }
            let oa = area(other)
            return frame.contains(o.centerX, o.centerY) && oa <= selfArea
                && selfArea <= wrapperAreaRatio * oa && related(item, other)
        }
        guard let anchor else { continue }
        dropped.insert(item.ref)
        if item.isInteractive { absorbedInteractive.insert(anchor.ref) }
    }
    if dropped.isEmpty { return Folded(items: items, collapsed: 0) }
    let kept = items.filter { !dropped.contains($0.ref) }.map { item -> CompactItem in
        guard absorbedInteractive.contains(item.ref), !item.isInteractive else { return item }
        var copy = item
        copy.isInteractive = true
        return copy
    }
    return Folded(items: kept, collapsed: dropped.count)
}

public struct CompactItem: Codable, Sendable {
    public var ref: String
    public var role: String
    public var testId: String?
    public var resourceId: String?
    public var label: String?
    public var frame: Rect?
    public var isEnabled: Bool
    public var isInteractive: Bool
    /// The in-app window this item belongs to, when it is inside one. A flat list
    /// from a stacked screen interleaves two windows by geometry; `occludedBy`
    /// carries this only indirectly and is overloaded with the keyboard and
    /// same-window popup cases.
    public var windowRef: String?
    /// True when this node holds input focus — where typed text will go. At most
    /// one item in an observation carries it.
    public var isFocused: Bool
    /// What sits on top of this node's tap point, when anything does: the ref
    /// of a higher z-order window (a dialog/popup covering a background page),
    /// or `CompactObservation.occluderKeyboard` for the system keyboard. A tap
    /// dispatched at this item would land on the occluder instead.
    public var occludedBy: String?
    /// Scroll capability when this item is a scrollable container — how an agent
    /// tells "this selector doesn't exist" from "it isn't bound yet".
    public var scroll: ScrollInfo?
    /// `"opaque"` / `"selection-only"` when this item is a wheel column, else nil.
    /// Rendered as `wheel:<value>` — the honest-boundary marker for a control whose
    /// candidate values exist only as pixels. See `Node.suspectedWheel`.
    public var wheel: String?
    /// True when this node hosts a web view whose DOM could not be read at capture
    /// time (a JS modal blocking the page's thread, JS off, or a read that outran
    /// its budget). Without it, "no DOM nodes" and "this web view is empty" are the
    /// same observation.
    public var domUnavailable: Bool
    /// True when this node is a suspected third-party WebView kernel (X5/UC): no
    /// DOM bridge exists for it at all — a structural boundary, not a degrade.
    public var domKernelUnsupported: Bool
    /// True when this node's pixels are missing from an IN-PROCESS screenshot (an
    /// iOS keyboard host window, an Android `SurfaceView`). The picture is not a
    /// second opinion for these — it silently omits them.
    public var pixelsUnavailable: Bool
    /// True when this window's DEVICE-level capture is blanked (Android
    /// `FLAG_SECURE`) while the in-process one is not. The complement of
    /// `pixelsUnavailable`.
    public var screencapBlank: Bool

    public init(
        ref: String,
        role: String,
        testId: String? = nil,
        resourceId: String? = nil,
        label: String? = nil,
        frame: Rect? = nil,
        isEnabled: Bool = true,
        isInteractive: Bool = false,
        windowRef: String? = nil,
        isFocused: Bool = false,
        occludedBy: String? = nil,
        scroll: ScrollInfo? = nil,
        wheel: String? = nil,
        domUnavailable: Bool = false,
        domKernelUnsupported: Bool = false,
        pixelsUnavailable: Bool = false,
        screencapBlank: Bool = false
    ) {
        self.ref = ref
        self.role = role
        self.testId = testId
        self.resourceId = resourceId
        self.label = label
        self.frame = frame
        self.isEnabled = isEnabled
        self.isInteractive = isInteractive
        self.windowRef = windowRef
        self.isFocused = isFocused
        self.occludedBy = occludedBy
        self.scroll = scroll
        self.wheel = wheel
        self.domUnavailable = domUnavailable
        self.domKernelUnsupported = domKernelUnsupported
        self.pixelsUnavailable = pixelsUnavailable
        self.screencapBlank = screencapBlank
    }

    /// One-line rendering for agent-facing text output. Matches reticle-core's `line()`.
    public func line() -> String {
        let selector: String
        if let testId { selector = "#\(testId)" }
        else if let resourceId { selector = "@\(resourceId)" }
        else { selector = ref }
        let labelPart = label.map { " \"\(String($0.prefix(40)))\"" } ?? ""
        let framePart = frame.map { " [\($0.intDescription)]" } ?? ""
        var state = ""
        if !isEnabled { state += " disabled" }
        if isInteractive { state += " tappable" }
        if isFocused { state += " focused" }
        if let occludedBy { state += " occluded-by:\(occludedBy)" }
        if let scroll, !scroll.describe().isEmpty { state += " " + scroll.describe() }
        if let wheel { state += " wheel:\(wheel)" }
        if domUnavailable { state += " dom:unavailable" }
        if domKernelUnsupported { state += " dom:unsupported-kernel" }
        if pixelsUnavailable { state += " pixels:unavailable" }
        if screencapBlank { state += " screencap:blank" }
        return "\(selector) \(role)\(labelPart)\(framePart)\(state)"
    }

    private enum CodingKeys: String, CodingKey {
        case ref, role, testId, resourceId, label, frame, isEnabled, isInteractive
        case isFocused, windowRef, occludedBy, scroll, wheel
        case domUnavailable, domKernelUnsupported, pixelsUnavailable, screencapBlank
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ref, forKey: .ref)
        try c.encode(role, forKey: .role)
        try c.encodeIfPresent(testId, forKey: .testId)
        try c.encodeIfPresent(resourceId, forKey: .resourceId)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(frame, forKey: .frame)
        if !isEnabled { try c.encode(isEnabled, forKey: .isEnabled) }
        if isInteractive { try c.encode(isInteractive, forKey: .isInteractive) }
        try c.encodeIfPresent(windowRef, forKey: .windowRef)
        if isFocused { try c.encode(isFocused, forKey: .isFocused) }
        try c.encodeIfPresent(occludedBy, forKey: .occludedBy)
        try c.encodeIfPresent(scroll, forKey: .scroll)
        try c.encodeIfPresent(wheel, forKey: .wheel)
        if domUnavailable { try c.encode(domUnavailable, forKey: .domUnavailable) }
        if domKernelUnsupported { try c.encode(domKernelUnsupported, forKey: .domKernelUnsupported) }
        if pixelsUnavailable { try c.encode(pixelsUnavailable, forKey: .pixelsUnavailable) }
        if screencapBlank { try c.encode(screencapBlank, forKey: .screencapBlank) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.decode(String.self, forKey: .ref)
        role = try c.decode(String.self, forKey: .role)
        testId = try c.decodeIfPresent(String.self, forKey: .testId)
        resourceId = try c.decodeIfPresent(String.self, forKey: .resourceId)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        frame = try c.decodeIfPresent(Rect.self, forKey: .frame)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isInteractive = try c.decodeIfPresent(Bool.self, forKey: .isInteractive) ?? false
        windowRef = try c.decodeIfPresent(String.self, forKey: .windowRef)
        isFocused = try c.decodeIfPresent(Bool.self, forKey: .isFocused) ?? false
        occludedBy = try c.decodeIfPresent(String.self, forKey: .occludedBy)
        scroll = try c.decodeIfPresent(ScrollInfo.self, forKey: .scroll)
        wheel = try c.decodeIfPresent(String.self, forKey: .wheel)
        domUnavailable = try c.decodeIfPresent(Bool.self, forKey: .domUnavailable) ?? false
        domKernelUnsupported = try c.decodeIfPresent(Bool.self, forKey: .domKernelUnsupported) ?? false
        pixelsUnavailable = try c.decodeIfPresent(Bool.self, forKey: .pixelsUnavailable) ?? false
        screencapBlank = try c.decodeIfPresent(Bool.self, forKey: .screencapBlank) ?? false
    }
}
