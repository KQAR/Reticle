import Foundation

/// Node origin. `axElement` is the iOS accessibility-derived SwiftUI element
/// (the SwiftUI analogue of Android's `composeSemantics`).
public enum NodeKind: String, Codable, Sendable {
    case application
    case window
    case view
    case composeSemantics
    case axElement
    case domNode
    case probe
}

/// The channel a style property was read through — the provenance half of
/// `Node.styleChannels`, the twin of reticle-core's `StyleChannel`.
///
/// Channels differ in what they can be trusted for, so collapsing them would
/// hide the difference: a `viewField` read is the live value the platform will
/// render, while a `drawableReflect` read walked a private `Drawable` field and
/// can be stale on a themed or animated background. A consumer comparing against
/// a design needs to know which it is holding.
public enum StyleChannel: String, Codable, Sendable {
    /// A public field/getter on the platform view or its layer.
    case viewField
    /// Compose: the `TextStyle` behind a laid-out `Text`, via `GetTextLayoutResult`.
    case textLayout
    /// WebView: `getComputedStyle` on the DOM element.
    case computedStyle
    /// Reflected out of an Android background `Drawable` — see the caveat above.
    case drawableReflect
}

/// The view-tree snapshot: a flat map of ref -> node plus a root ref.
///
/// On iOS the tree is rooted at a synthetic application node, then each
/// `UIWindowScene` window, then the `UIView` hierarchy.
public struct Snapshot: Codable, Sendable {
    public static let schemaVersionValue = 1

    public var schemaVersion: Int
    /// Wall-clock millis when captured, stamped by the agent.
    public var capturedAtMillis: Int64
    public var platform: String
    public var screen: ScreenInfo
    public var rootRef: String
    public var nodes: [String: Node]

    public init(
        schemaVersion: Int = Snapshot.schemaVersionValue,
        capturedAtMillis: Int64,
        platform: String,
        screen: ScreenInfo,
        rootRef: String,
        nodes: [String: Node]
    ) {
        self.schemaVersion = schemaVersion
        self.capturedAtMillis = capturedAtMillis
        self.platform = platform
        self.screen = screen
        self.rootRef = rootRef
        self.nodes = nodes
    }

    public func node(_ ref: String) -> Node? { nodes[ref] }
    public func root() -> Node? { nodes[rootRef] }

    /// First node satisfying `match` in **document order**: depth-first from the
    /// root, then any unreached ref in sorted order (an orphan window captured out
    /// of band stays addressable, but never outranks a node that is in the tree).
    ///
    /// Deliberately not `nodes.values.first` — a Swift dictionary's iteration
    /// order is unspecified and hash-seeded per process, so a first-match lookup
    /// over duplicate ids answered differently between two runs of one command.
    public func first(where match: (Node) -> Bool) -> Node? {
        var seen = Set<String>()
        var found: Node?
        func visit(_ ref: String) {
            guard found == nil, !seen.contains(ref) else { return }
            seen.insert(ref)
            guard let node = nodes[ref] else { return }
            if match(node) { found = node; return }
            for child in node.children { visit(child) }
        }
        visit(rootRef)
        for ref in nodes.keys.sorted() where found == nil { visit(ref) }
        return found
    }
    public func children(of ref: String) -> [Node] {
        (nodes[ref]?.children ?? []).compactMap { nodes[$0] }
    }
}

/// A single node in the unified UI tree.
public struct Node: Codable, Sendable {
    public var ref: String
    public var parentRef: String?
    public var kind: NodeKind
    public var typeName: String
    public var role: String?
    public var resourceId: String?
    public var contentDescription: String?
    public var text: String?
    public var testId: String?
    public var frame: Rect?
    public var isVisible: Bool
    public var isEnabled: Bool
    public var isInteractive: Bool
    public var custom: [String: MetadataValue]
    /// Where each style-bearing entry of `custom` was read from, keyed by the same
    /// property name. Absent for non-style properties, so it doubles as the
    /// allowlist of which `custom` keys are style.
    ///
    /// It exists because "the design says 600, the app has nothing" has two very
    /// different causes — the app really set no weight, or Reticle has no channel
    /// to that weight — and a missing key alone cannot tell them apart.
    public var styleChannels: [String: StyleChannel]
    /// Style properties this node is known to HAVE but which no channel can read,
    /// keyed by property name with a short reason (e.g. `backgroundColor` ->
    /// `compose-draw-modifier`). The boundary rule at property granularity: an
    /// unreachable thing names itself rather than looking absent. A key here is
    /// never also a key of `custom` or `styleChannels`.
    public var styleGaps: [String: String]
    public var children: [String]
    public var regions: [InteractionRegion]
    public var suspectedMultiRegion: Bool
    public var charGrid: CharGrid?
    /// Scroll capability, when this node is a scrollable container; nil otherwise.
    public var scroll: ScrollInfo?

    public init(
        ref: String,
        parentRef: String? = nil,
        kind: NodeKind,
        typeName: String,
        role: String? = nil,
        resourceId: String? = nil,
        contentDescription: String? = nil,
        text: String? = nil,
        testId: String? = nil,
        frame: Rect? = nil,
        isVisible: Bool = true,
        isEnabled: Bool = true,
        isInteractive: Bool = false,
        custom: [String: MetadataValue] = [:],
        styleChannels: [String: StyleChannel] = [:],
        styleGaps: [String: String] = [:],
        children: [String] = [],
        regions: [InteractionRegion] = [],
        suspectedMultiRegion: Bool = false,
        charGrid: CharGrid? = nil,
        scroll: ScrollInfo? = nil
    ) {
        self.ref = ref
        self.parentRef = parentRef
        self.kind = kind
        self.typeName = typeName
        self.role = role
        self.resourceId = resourceId
        self.contentDescription = contentDescription
        self.text = text
        self.testId = testId
        self.frame = frame
        self.isVisible = isVisible
        self.isEnabled = isEnabled
        self.isInteractive = isInteractive
        self.custom = custom
        self.styleChannels = styleChannels
        self.styleGaps = styleGaps
        self.children = children
        self.regions = regions
        self.suspectedMultiRegion = suspectedMultiRegion
        self.charGrid = charGrid
        self.scroll = scroll
    }

    /// True when this node carries a signal an agent can target it by. The
    /// single source of truth shared by the semantic-tree and compact-observation
    /// projections, matching reticle-core's `hasTargetingSignal()`.
    /// True when this node hosts a web view whose DOM could not be read at capture
    /// time. The agents set `custom["domStatus"] = "unavailable"`; this is the one
    /// place that spelling is interpreted.
    public func domUnavailable() -> Bool {
        if case .text(let v)? = custom["domStatus"] { return v == "unavailable" }
        return false
    }

    /// True when this node is a **suspected third-party WebView kernel** (X5/TBS,
    /// UC, …): a class whose name says WebView but which is not the platform web
    /// view, so no DOM bridge can attach. Android-only in practice — iOS has one
    /// web engine — but the spelling lives here so the protocol stays symmetric.
    /// Unlike `domUnavailable()`, this is structural: retrying never helps.
    public func domKernelUnsupported() -> Bool {
        if case .text(let v)? = custom["domStatus"] { return v == "unsupportedKernel" }
        return false
    }

    /// True when this node's pixels are NOT in an in-process screenshot: an iOS
    /// keyboard host window refuses to render into a borrowed context (measured: the
    /// whole keyboard is absent from the agent's picture while a device capture shows
    /// it), and an Android `SurfaceView` leaves a transparent hole. Agents set
    /// `custom["pixelStatus"] = "unavailable"`; this is the one place that spelling
    /// is interpreted.
    public func pixelsUnavailable() -> Bool {
        if case .text(let v)? = custom["pixelStatus"] { return v == "unavailable" }
        return false
    }

    /// The mirror image: a window whose DEVICE-level capture comes back blanked
    /// (Android `FLAG_SECURE`) while the in-process capture is unaffected. Agents set
    /// `custom["screencapStatus"] = "blank"`.
    public func screencapBlank() -> Bool {
        if case .text(let v)? = custom["screencapStatus"] { return v == "blank" }
        return false
    }

    /// The CSS selector a WebView DOM node was emitted with, the twin of the
    /// Kotlin `Node.domCssSelector()`. Present only on `NodeKind.domNode`.
    public func domCssSelector() -> String? {
        if case .text(let v)? = custom["domCssSelector"] { return v }
        return nil
    }

    public func hasTargetingSignal() -> Bool {
        testId != nil
            || resourceId != nil
            || contentDescription != nil
            || !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isInteractive
    }

    private enum CodingKeys: String, CodingKey {
        case ref, parentRef, kind, typeName, role, resourceId, contentDescription
        case text, testId, frame, isVisible, isEnabled, isInteractive, custom
        case styleChannels, styleGaps
        case children, regions, suspectedMultiRegion, charGrid, scroll
    }

    // Custom encode to reproduce reticle-core's omit-defaults JSON: a field
    // equal to its default (nil, true for isVisible/isEnabled, false for the
    // rest, or an empty collection) is omitted, so a missing field decodes back
    // to that default. This keeps the snapshot token-cheap and byte-compatible
    // with the Kotlin agent.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ref, forKey: .ref)
        try c.encodeIfPresent(parentRef, forKey: .parentRef)
        try c.encode(kind, forKey: .kind)
        try c.encode(typeName, forKey: .typeName)
        try c.encodeIfPresent(role, forKey: .role)
        try c.encodeIfPresent(resourceId, forKey: .resourceId)
        try c.encodeIfPresent(contentDescription, forKey: .contentDescription)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(testId, forKey: .testId)
        try c.encodeIfPresent(frame, forKey: .frame)
        if !isVisible { try c.encode(isVisible, forKey: .isVisible) }
        if !isEnabled { try c.encode(isEnabled, forKey: .isEnabled) }
        if isInteractive { try c.encode(isInteractive, forKey: .isInteractive) }
        if !custom.isEmpty { try c.encode(custom, forKey: .custom) }
        if !styleChannels.isEmpty { try c.encode(styleChannels, forKey: .styleChannels) }
        if !styleGaps.isEmpty { try c.encode(styleGaps, forKey: .styleGaps) }
        if !children.isEmpty { try c.encode(children, forKey: .children) }
        if !regions.isEmpty { try c.encode(regions, forKey: .regions) }
        if suspectedMultiRegion { try c.encode(suspectedMultiRegion, forKey: .suspectedMultiRegion) }
        try c.encodeIfPresent(charGrid, forKey: .charGrid)
        try c.encodeIfPresent(scroll, forKey: .scroll)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.decode(String.self, forKey: .ref)
        parentRef = try c.decodeIfPresent(String.self, forKey: .parentRef)
        kind = try c.decode(NodeKind.self, forKey: .kind)
        typeName = try c.decode(String.self, forKey: .typeName)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        resourceId = try c.decodeIfPresent(String.self, forKey: .resourceId)
        contentDescription = try c.decodeIfPresent(String.self, forKey: .contentDescription)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        testId = try c.decodeIfPresent(String.self, forKey: .testId)
        frame = try c.decodeIfPresent(Rect.self, forKey: .frame)
        isVisible = try c.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isInteractive = try c.decodeIfPresent(Bool.self, forKey: .isInteractive) ?? false
        custom = try c.decodeIfPresent([String: MetadataValue].self, forKey: .custom) ?? [:]
        styleChannels = try c.decodeIfPresent([String: StyleChannel].self, forKey: .styleChannels) ?? [:]
        styleGaps = try c.decodeIfPresent([String: String].self, forKey: .styleGaps) ?? [:]
        children = try c.decodeIfPresent([String].self, forKey: .children) ?? []
        regions = try c.decodeIfPresent([InteractionRegion].self, forKey: .regions) ?? []
        suspectedMultiRegion = try c.decodeIfPresent(Bool.self, forKey: .suspectedMultiRegion) ?? false
        charGrid = try c.decodeIfPresent(CharGrid.self, forKey: .charGrid)
        scroll = try c.decodeIfPresent(ScrollInfo.self, forKey: .scroll)
    }
}

/// A container's scroll capability — the Swift twin of reticle-core's
/// `ScrollInfo`.
///
/// The evidence behind the commonest E2E dead end: a recycling list keeps only
/// its visible window bound, so a far-down row has no node, no frame, and no
/// selector — not merely an off-screen one. Flags say whether the container can
/// still move in each direction right now; they are NOT a claim about what would
/// come into view.
public struct ScrollInfo: Codable, Sendable, Equatable {
    public var canScrollUp: Bool
    public var canScrollDown: Bool
    public var canScrollLeft: Bool
    public var canScrollRight: Bool

    public init(
        canScrollUp: Bool = false,
        canScrollDown: Bool = false,
        canScrollLeft: Bool = false,
        canScrollRight: Bool = false
    ) {
        self.canScrollUp = canScrollUp
        self.canScrollDown = canScrollDown
        self.canScrollLeft = canScrollLeft
        self.canScrollRight = canScrollRight
    }

    public var isScrollable: Bool {
        canScrollUp || canScrollDown || canScrollLeft || canScrollRight
    }

    /// Compact rendering, e.g. "scroll:down" / "scroll:up,down".
    public func describe() -> String {
        var parts: [String] = []
        if canScrollUp { parts.append("up") }
        if canScrollDown { parts.append("down") }
        if canScrollLeft { parts.append("left") }
        if canScrollRight { parts.append("right") }
        return parts.isEmpty ? "" : "scroll:" + parts.joined(separator: ",")
    }

    private enum CodingKeys: String, CodingKey {
        case canScrollUp, canScrollDown, canScrollLeft, canScrollRight
    }

    // Omit-defaults JSON, matching the Kotlin encoder.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if canScrollUp { try c.encode(canScrollUp, forKey: .canScrollUp) }
        if canScrollDown { try c.encode(canScrollDown, forKey: .canScrollDown) }
        if canScrollLeft { try c.encode(canScrollLeft, forKey: .canScrollLeft) }
        if canScrollRight { try c.encode(canScrollRight, forKey: .canScrollRight) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        canScrollUp = try c.decodeIfPresent(Bool.self, forKey: .canScrollUp) ?? false
        canScrollDown = try c.decodeIfPresent(Bool.self, forKey: .canScrollDown) ?? false
        canScrollLeft = try c.decodeIfPresent(Bool.self, forKey: .canScrollLeft) ?? false
        canScrollRight = try c.decodeIfPresent(Bool.self, forKey: .canScrollRight) ?? false
    }
}
