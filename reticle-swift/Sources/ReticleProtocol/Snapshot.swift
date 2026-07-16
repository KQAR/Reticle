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
    public var children: [String]
    public var regions: [InteractionRegion]
    public var suspectedMultiRegion: Bool
    public var charGrid: CharGrid?

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
        children: [String] = [],
        regions: [InteractionRegion] = [],
        suspectedMultiRegion: Bool = false,
        charGrid: CharGrid? = nil
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
        self.children = children
        self.regions = regions
        self.suspectedMultiRegion = suspectedMultiRegion
        self.charGrid = charGrid
    }

    /// True when this node carries a signal an agent can target it by. The
    /// single source of truth shared by the semantic-tree and compact-observation
    /// projections, matching reticle-core's `hasTargetingSignal()`.
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
        case children, regions, suspectedMultiRegion, charGrid
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
        if !children.isEmpty { try c.encode(children, forKey: .children) }
        if !regions.isEmpty { try c.encode(regions, forKey: .regions) }
        if suspectedMultiRegion { try c.encode(suspectedMultiRegion, forKey: .suspectedMultiRegion) }
        try c.encodeIfPresent(charGrid, forKey: .charGrid)
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
        children = try c.decodeIfPresent([String].self, forKey: .children) ?? []
        regions = try c.decodeIfPresent([InteractionRegion].self, forKey: .regions) ?? []
        suspectedMultiRegion = try c.decodeIfPresent(Bool.self, forKey: .suspectedMultiRegion) ?? false
        charGrid = try c.decodeIfPresent(CharGrid.self, forKey: .charGrid)
    }
}
