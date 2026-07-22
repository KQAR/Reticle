import Foundation

/// Token-cheap summary: one line per interactive or labelled node. Mirrors
/// reticle-core's `CompactObservation`.
public struct CompactObservation: Codable, Sendable {
    public var capturedAtMillis: Int64
    public var screen: ScreenInfo
    public var items: [CompactItem]

    /// `CompactItem.occludedBy` value for the system keyboard (IME).
    public static let occluderKeyboard = "keyboard"

    public init(capturedAtMillis: Int64, screen: ScreenInfo, items: [CompactItem]) {
        self.capturedAtMillis = capturedAtMillis
        self.screen = screen
        self.items = items
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
                        occludedBy: occluderOf(node, windowRef: currentWindow)
                    )
                )
            }
            for c in node.children { visit(c, currentWindow) }
        }
        visit(snapshot.rootRef, nil)
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
    /// What sits on top of this node's tap point, when anything does: the ref
    /// of a higher z-order window (a dialog/popup covering a background page),
    /// or `CompactObservation.occluderKeyboard` for the system keyboard. A tap
    /// dispatched at this item would land on the occluder instead.
    public var occludedBy: String?

    public init(
        ref: String,
        role: String,
        testId: String? = nil,
        resourceId: String? = nil,
        label: String? = nil,
        frame: Rect? = nil,
        isEnabled: Bool = true,
        isInteractive: Bool = false,
        occludedBy: String? = nil
    ) {
        self.ref = ref
        self.role = role
        self.testId = testId
        self.resourceId = resourceId
        self.label = label
        self.frame = frame
        self.isEnabled = isEnabled
        self.isInteractive = isInteractive
        self.occludedBy = occludedBy
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
        if let occludedBy { state += " occluded-by:\(occludedBy)" }
        return "\(selector) \(role)\(labelPart)\(framePart)\(state)"
    }

    private enum CodingKeys: String, CodingKey {
        case ref, role, testId, resourceId, label, frame, isEnabled, isInteractive, occludedBy
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
        try c.encodeIfPresent(occludedBy, forKey: .occludedBy)
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
        occludedBy = try c.decodeIfPresent(String.self, forKey: .occludedBy)
    }
}
