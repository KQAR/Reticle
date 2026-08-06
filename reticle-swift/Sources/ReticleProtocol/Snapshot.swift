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
/// Toggle state of a checkable control. See `Node.checked` — the absence of this
/// value is itself an answer ("not a checkable control"), which is why the field
/// is optional rather than a `Bool` defaulting to false.
public enum CheckedState: String, Codable, Sendable {
    case on
    case off
    /// A tri-state control (a "select all" that covers a partial selection):
    /// `aria-checked="mixed"`, Android `ToggleableState.Indeterminate`.
    case mixed
}

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

    /// Gate every snapshot INGESTED from outside the process (agent HTTP, a
    /// `--snapshot` file). Checked at ingestion, not at decode: the decoder
    /// ignores unknown keys (it must, for additive changes), so a NEWER
    /// producer's renamed field would silently decode into a default —
    /// `isVisible=true` for a field that moved — and the projection would
    /// present invented evidence as real. Returns self so ingestion sites stay
    /// one expression. Mirrors reticle-core's `requireSupportedSchema`.
    @discardableResult
    public func requireSupportedSchema() throws -> Snapshot {
        if schemaVersion > Snapshot.schemaVersionValue {
            throw UnsupportedSnapshotSchema(found: schemaVersion)
        }
        return self
    }

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

/// A snapshot whose wire format is NEWER than this build understands — see
/// `Snapshot.requireSupportedSchema()`. An observer that cannot read the input
/// says so; it does not guess.
public struct UnsupportedSnapshotSchema: Error, CustomStringConvertible {
    public let found: Int
    public var description: String {
        "snapshot schemaVersion=\(found) is newer than this build understands "
            + "(max \(Snapshot.schemaVersionValue)). Upgrade the host to at least the "
            + "agent's version — a newer producer's fields would silently decode as defaults."
    }
}

/// A single node in the unified UI tree.
public extension Snapshot {
    /// The in-app windows of this capture, bottom-most first — the root's `window`
    /// children in the platform's stacking order. The Swift twin of reticle-core's
    /// `Snapshot.windowRefs()`.
    func windowRefs() -> [String] {
        (root()?.children ?? []).filter { nodes[$0]?.kind == .window }
    }

    /// The window on top, or nil when this capture has no window nodes.
    func topWindowRef() -> String? {
        windowRefs().last { nodes[$0]?.isVisible != false }
    }

    /// The nearest `window` ancestor of a node, or nil outside any window.
    func windowRefOf(_ ref: String) -> String? {
        var current = nodes[ref]
        var seen = Set<String>()
        while let node = current, seen.insert(node.ref).inserted {
            if node.kind == .window { return node.ref }
            current = node.parentRef.flatMap { nodes[$0] }
        }
        return nil
    }

    /// This capture narrowed to ONE window (`"top"` for the topmost), keeping the
    /// application root above it; nil when the argument names no window here.
    ///
    /// Scoping the SNAPSHOT rather than each renderer is what makes every view —
    /// tree, compact, outline, style — narrow identically. See the Kotlin twin for
    /// the full rationale.
    func scopedToWindow(_ window: String) -> Snapshot? {
        let refs = windowRefs()
        let targetRef = window == Snapshot.topWindow ? topWindowRef() : (refs.contains(window) ? window : nil)
        guard let targetRef, let target = nodes[targetRef] else { return nil }
        var kept: [String: Node] = [:]
        if var rootNode = root() {
            rootNode.children = [target.ref]
            kept[rootNode.ref] = rootNode
        }
        func visit(_ ref: String) {
            guard let node = nodes[ref], kept[ref] == nil else { return }
            kept[ref] = node
            node.children.forEach(visit)
        }
        visit(target.ref)
        var scoped = self
        scoped.nodes = kept
        return scoped
    }

    /// `scopedToWindow` argument for "whatever window is on top right now".
    static var topWindow: String { "top" }
}

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
    /// Can this node take input focus **from a touch** (Android:
    /// `focusableInTouchMode`)? Distinct from `isInteractive`, which is true for
    /// anything clickable: a compound input widget's outer container is clickable
    /// but only the nested field can accept text. False where the platform has no
    /// per-node focus channel (Compose semantics, DOM elements) — there the
    /// platform focus sits on the host view above it.
    public var isFocusable: Bool
    /// Does this node hold input focus right now? At most one node in a tree does.
    /// The post-condition `act type` checks after tapping its target field.
    public var isFocused: Bool
    /// Toggle state of a checkable control, or nil when this node is not
    /// checkable at all.
    ///
    /// Nil and `.off` are deliberately different answers. "There is no checkbox
    /// here" and "there is a checkbox and it is unticked" lead to opposite next
    /// actions, and a plain `Bool` would have collapsed them — which is how a
    /// consent row reads as unticked forever. See the Kotlin twin.
    public var checked: CheckedState?
    /// Disclosure state of a control that opens something (`aria-expanded`), nil
    /// when it declares none. Nil and `false` are different facts, for the same
    /// reason `checked` keeps its third state — and reading it is the only way to
    /// verify a tap on a dropdown trigger, since a div-built select materialises
    /// its options only once opened. See the Kotlin twin.
    public var expanded: Bool?
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
    /// True when this node looks like a WHEEL column — a control that paints its
    /// candidate values onto its own canvas instead of materialising them as nodes.
    /// A hint from the widget's class family, not a claim: without it a wheel is
    /// indistinguishable from a decorative empty view. See the Kotlin twin.
    public var suspectedWheel: Bool
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
        isFocusable: Bool = false,
        isFocused: Bool = false,
        checked: CheckedState? = nil,
        expanded: Bool? = nil,
        custom: [String: MetadataValue] = [:],
        styleChannels: [String: StyleChannel] = [:],
        styleGaps: [String: String] = [:],
        children: [String] = [],
        regions: [InteractionRegion] = [],
        suspectedMultiRegion: Bool = false,
        suspectedWheel: Bool = false,
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
        self.isFocusable = isFocusable
        self.isFocused = isFocused
        self.checked = checked
        self.expanded = expanded
        self.custom = custom
        self.styleChannels = styleChannels
        self.styleGaps = styleGaps
        self.children = children
        self.regions = regions
        self.suspectedMultiRegion = suspectedMultiRegion
        self.suspectedWheel = suspectedWheel
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

    /// What kind of popup this control declares it opens (`aria-haspopup`), nil
    /// otherwise. A hint the PAGE published rather than one Reticle inferred, which
    /// is what makes it actionable: an empty tree under such a control is expected
    /// before it is opened. See the Kotlin twin.
    public func domHasPopup() -> String? {
        if case .text(let v)? = custom["domHasPopup"] { return v }
        return nil
    }

    /// How many DOM nodes were captured before the traversal hit its own node cap,
    /// nil when it walked the whole document. Unlike the projection's cap, the
    /// nodes past this one were never captured, so nothing further down can reach
    /// them. See the Kotlin twin.
    public func domCappedAt() -> Int64? {
        guard case .bool(true)? = custom["domCapped"] else { return nil }
        if case .integer(let n)? = custom["domCaptured"] { return n }
        return 0
    }

    /// True when this is an `<iframe>` whose document the page may not read — a
    /// structural browser-policy boundary. Previously unmarked, and its absence is
    /// byte-for-byte what a frame still loading looks like, so a caller retried and
    /// eventually measured pixels. See the Kotlin twin.
    public func domCrossOriginFrame() -> Bool {
        if case .bool(let v)? = custom["domCrossOriginFrame"] { return v }
        return false
    }

    /// Why a frame's subtree is empty: `"cross-origin"`, `"sandboxed"`, or
    /// `"not-loaded"` — nil when this frame's document WAS read, or this is not a
    /// frame. The three demand opposite moves from a caller (use coordinates, fix the
    /// page, retry) and used to be one flag. See the Kotlin twin.
    public func domFrameOpaque() -> String? {
        if case .text(let v)? = custom["domFrameOpaque"], !v.isEmpty { return v }
        return nil
    }

    /// The frame's `name` attribute, its document URL, and how many frames are nested
    /// inside it — read from the PARENT document, so they survive a frame whose
    /// contents do not. See the Kotlin twin.
    public func domFrameName() -> String? {
        if case .text(let v)? = custom["domFrameName"], !v.isEmpty { return v }
        return nil
    }

    public func domFrameUrl() -> String? {
        if case .text(let v)? = custom["domFrameUrl"], !v.isEmpty { return v }
        return nil
    }

    public func domFrameChildCount() -> Int64? {
        if case .integer(let n)? = custom["domFrameChildCount"] { return n }
        return nil
    }

    /// True when a frame in this node's chain is rotated or skewed, so `frame` is the
    /// axis-aligned hull of the real box rather than the box. See the Kotlin twin.
    public func domGeometryApprox() -> Bool {
        if case .bool(let v)? = custom["domGeometryApprox"] { return v }
        return false
    }

    /// The element's tag name, lowercased by the traversal script.
    public func domTag() -> String? {
        if case .text(let v)? = custom["domTag"] { return v }
        return nil
    }

    /// The element's `id` attribute. Also mirrored into `testId`.
    public func domId() -> String? {
        if case .text(let v)? = custom["domId"] { return v }
        return nil
    }

    /// The element's class list, split from the captured `class` attribute.
    public func domClasses() -> [String] {
        guard case .text(let v)? = custom["domClass"] else { return [] }
        return v.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    }

    /// A DOM input's `placeholder` attribute, kept apart from its value.
    public func domPlaceholder() -> String? {
        if case .text(let v)? = custom["domPlaceholder"] { return v }
        return nil
    }

    /// This element's 1-based position among siblings with the SAME tag, as the page
    /// counted it. Read in the page rather than derived from the captured tree: the
    /// walk drops hidden elements, so counting captured children would answer
    /// `:nth-of-type(3)` with the third VISIBLE sibling and tap the wrong control.
    public func domNthOfType() -> Int? {
        if case .integer(let n)? = custom["domNthOfType"] { return Int(n) }
        return nil
    }

    /// This element's 1-based position among ALL element siblings. See `domNthOfType`.
    public func domNthChild() -> Int? {
        if case .integer(let n)? = custom["domNthChild"] { return Int(n) }
        return nil
    }

    /// The prompt a field shows while it is empty, whichever platform it came from:
    /// a DOM `placeholder`, or a native `hint` / `UITextField.placeholder`. One
    /// accessor because the caller's question is the same either way — see the
    /// Kotlin twin for the measurement that made the native half necessary.
    public func placeholder() -> String? {
        if let dom = domPlaceholder() { return dom }
        if case .text(let v)? = custom["nativeHint"] { return v }
        return nil
    }

    /// The most characters this field will accept, when it says so (Android's
    /// `LengthFilter`). UIKit has no readable equivalent.
    public func maxLength() -> Int? {
        if case .integer(let n)? = custom["maxLength"] { return Int(n) }
        return nil
    }

    /// What a wheel column publishes about itself — see the Kotlin twin for the
    /// measurement. Nil for a self-drawn wheel, which publishes none of it.
    public func wheelValue() -> String? {
        if case .text(let v)? = custom["wheelValue"] { return v }
        return nil
    }

    /// The selection's 0-based index within `wheelMin()...wheelMax()`.
    public func wheelIndex() -> Int? {
        if case .integer(let n)? = custom["wheelIndex"] { return Int(n) }
        return nil
    }

    /// See `wheelValue()`.
    public func wheelMin() -> Int? {
        if case .integer(let n)? = custom["wheelMin"] { return Int(n) }
        return nil
    }

    /// See `wheelValue()`.
    public func wheelMax() -> Int? {
        if case .integer(let n)? = custom["wheelMax"] { return Int(n) }
        return nil
    }

    /// The item labels this wheel offers, truncated at the capture's own cap.
    public func wheelItems() -> [String] {
        guard case .text(let v)? = custom["wheelItems"] else { return [] }
        return v.split(separator: ",").map(String.init)
    }

    /// How many labels `wheelItems()` left out, when it left any out.
    public func wheelItemsTruncated() -> Int? {
        if case .integer(let n)? = custom["wheelItemsTruncated"] { return Int(n) }
        return nil
    }

    /// The pixel distance one value travels — the quantum a swipe must be a multiple
    /// of, which the caller used to measure off a screenshot.
    public func wheelRowHeightPx() -> Int? {
        if case .integer(let n)? = custom["wheelRowHeightPx"] { return Int(n) }
        return nil
    }

    /// True when `wheelRowHeightPx()` is `height / 3`, not a reading.
    public func wheelRowHeightEstimated() -> Bool {
        if case .bool(true)? = custom["wheelRowHeightEstimated"] { return true }
        return false
    }

    /// The message this field declares itself invalid with: `""` when it sets
    /// `aria-invalid` and names nothing, the `aria-describedby` text when it does,
    /// nil when the field does not declare itself invalid. Three states, because
    /// "valid" and "invalid, reason not stated" are different readings.
    public func domInvalidMessage() -> String? {
        guard case .bool(true)? = custom["domInvalid"] else { return nil }
        if case .text(let v)? = custom["domDescribedBy"] { return v }
        return ""
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

    /// The class name behind `domKernelUnsupported()`, for reporting. Twin of
    /// reticle-core's `Node.domKernelName()`.
    public func domKernelName() -> String? {
        if case .text(let v)? = custom["domKernel"] { return v }
        return nil
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
            // A DISABLED input is not interactive and, on a form built from
            // framework components, has no id, no label and no value — so every
            // clause above is false and it used to be filtered out of the
            // projection entirely. Measured: address fields disabled until a
            // postcode unlocked them were absent from the compact view, which
            // reads as "the app has no such field" rather than "not ready yet".
            || placeholder() != nil
    }

    private enum CodingKeys: String, CodingKey {
        case ref, parentRef, kind, typeName, role, resourceId, contentDescription
        case text, testId, frame, isVisible, isEnabled, isInteractive
        case isFocusable, isFocused, checked, expanded, custom
        case styleChannels, styleGaps
        case children, regions, suspectedMultiRegion, suspectedWheel, charGrid, scroll
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
        if isFocusable { try c.encode(isFocusable, forKey: .isFocusable) }
        if isFocused { try c.encode(isFocused, forKey: .isFocused) }
        try c.encodeIfPresent(checked, forKey: .checked)
        try c.encodeIfPresent(expanded, forKey: .expanded)
        if !custom.isEmpty { try c.encode(custom, forKey: .custom) }
        if !styleChannels.isEmpty { try c.encode(styleChannels, forKey: .styleChannels) }
        if !styleGaps.isEmpty { try c.encode(styleGaps, forKey: .styleGaps) }
        if !children.isEmpty { try c.encode(children, forKey: .children) }
        if !regions.isEmpty { try c.encode(regions, forKey: .regions) }
        if suspectedMultiRegion { try c.encode(suspectedMultiRegion, forKey: .suspectedMultiRegion) }
        if suspectedWheel { try c.encode(suspectedWheel, forKey: .suspectedWheel) }
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
        isFocusable = try c.decodeIfPresent(Bool.self, forKey: .isFocusable) ?? false
        isFocused = try c.decodeIfPresent(Bool.self, forKey: .isFocused) ?? false
        checked = try c.decodeIfPresent(CheckedState.self, forKey: .checked)
        expanded = try c.decodeIfPresent(Bool.self, forKey: .expanded)
        custom = try c.decodeIfPresent([String: MetadataValue].self, forKey: .custom) ?? [:]
        styleChannels = try c.decodeIfPresent([String: StyleChannel].self, forKey: .styleChannels) ?? [:]
        styleGaps = try c.decodeIfPresent([String: String].self, forKey: .styleGaps) ?? [:]
        children = try c.decodeIfPresent([String].self, forKey: .children) ?? []
        regions = try c.decodeIfPresent([InteractionRegion].self, forKey: .regions) ?? []
        suspectedMultiRegion = try c.decodeIfPresent(Bool.self, forKey: .suspectedMultiRegion) ?? false
        suspectedWheel = try c.decodeIfPresent(Bool.self, forKey: .suspectedWheel) ?? false
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
