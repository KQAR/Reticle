import Foundation

/// Token-cheap summary: one line per interactive or labelled node. Mirrors
/// reticle-core's `CompactObservation`.
public struct CompactObservation: Codable, Sendable {
    public var capturedAtMillis: Int64
    public var screen: ScreenInfo
    public var items: [CompactItem]

    public init(capturedAtMillis: Int64, screen: ScreenInfo, items: [CompactItem]) {
        self.capturedAtMillis = capturedAtMillis
        self.screen = screen
        self.items = items
    }

    /// Build from a snapshot, keeping interactive or labelled *visible* nodes.
    public static func from(_ snapshot: Snapshot, maxItems: Int = 200) -> CompactObservation {
        var items: [CompactItem] = []
        func visit(_ ref: String) {
            guard let node = snapshot.nodes[ref] else { return }
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
                        isInteractive: node.isInteractive
                    )
                )
            }
            for c in node.children { visit(c) }
        }
        visit(snapshot.rootRef)
        return CompactObservation(
            capturedAtMillis: snapshot.capturedAtMillis,
            screen: snapshot.screen,
            items: Array(items.prefix(maxItems))
        )
    }
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

    public init(
        ref: String,
        role: String,
        testId: String? = nil,
        resourceId: String? = nil,
        label: String? = nil,
        frame: Rect? = nil,
        isEnabled: Bool = true,
        isInteractive: Bool = false
    ) {
        self.ref = ref
        self.role = role
        self.testId = testId
        self.resourceId = resourceId
        self.label = label
        self.frame = frame
        self.isEnabled = isEnabled
        self.isInteractive = isInteractive
    }

    /// One-line rendering for agent-facing text output. Matches reticle-core's `line()`.
    public func line() -> String {
        let selector: String
        if let testId { selector = "#\(testId)" }
        else if let resourceId { selector = "@\(resourceId)" }
        else { selector = ref }
        let labelPart = label.map { " \"\(String($0.prefix(40)))\"" } ?? ""
        let framePart = frame.map {
            " [\(Int($0.x)),\(Int($0.y)) \(Int($0.width))x\(Int($0.height))]"
        } ?? ""
        var state = ""
        if !isEnabled { state += " disabled" }
        if isInteractive { state += " tappable" }
        return "\(selector) \(role)\(labelPart)\(framePart)\(state)"
    }

    private enum CodingKeys: String, CodingKey {
        case ref, role, testId, resourceId, label, frame, isEnabled, isInteractive
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
    }
}
