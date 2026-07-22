import Foundation

/// Wire endpoints shared by the in-app server and the host. Mirrors
/// reticle-core's `Endpoints`.
public enum Endpoints {
    public static let runtime = "/runtime"
    public static let report = "/report"
    public static let snapshot = "/snapshot"
    public static let semantics = "/semantics"
    public static let compact = "/compact"
    public static let logs = "/logs"
    public static let screenshot = "/screenshot"
    public static let mutate = "/mutate"
    public static let clipboard = "/clipboard"

    /// In-process control activation (POST, body: ActivationRequest). The agent
    /// resolves the selector to a control and fires its action from *inside* the
    /// app, so it works on a real device where host-side HID synthesis cannot
    /// reach — the on-device analogue of a tap. Limited to activatable targets.
    public static let activate = "/activate"

    /// Current system-keyboard state, probed from inside the app (GET).
    public static let keyboard = "/keyboard"

    /// Dismiss the system keyboard from inside the app process (POST, no body):
    /// resignFirstResponder on iOS, InputMethodManager on Android. Answers with
    /// the settled post-hide state.
    public static let keyboardHide = "/keyboard/hide"
}

/// Answer of `Endpoints.keyboardHide`: what was on screen, and what is now.
/// Mirrors reticle-core's `KeyboardHideResult`.
public struct KeyboardHideResult: Codable, Sendable {
    public var wasVisible: Bool
    public var keyboard: KeyboardInfo

    public init(wasVisible: Bool, keyboard: KeyboardInfo) {
        self.wasVisible = wasVisible
        self.keyboard = keyboard
    }
}

/// Request to activate a control in-process (the on-device "tap").
public struct ActivationRequest: Codable, Sendable {
    public var selector: Selector
    public init(selector: Selector) { self.selector = selector }
}

/// Result of an in-process activation. `activated` is false with a `message` of
/// "unsupported_activation_target" when the resolved node cannot be activated
/// programmatically (not a control and no accessibility activation action).
public struct ActivationResult: Codable, Sendable {
    public var activated: Bool
    public var ref: String?
    public var typeName: String?
    public var via: String?
    public var message: String?

    public init(activated: Bool, ref: String? = nil, typeName: String? = nil, via: String? = nil, message: String? = nil) {
        self.activated = activated
        self.ref = ref
        self.typeName = typeName
        self.via = via
        self.message = message
    }
}

/// Identifies the running app process behind the loopback server. The Android
/// field names are kept verbatim for wire compatibility; on iOS `packageName`
/// carries the bundle identifier and `sdkInt` the major OS version.
public struct RuntimeInfo: Codable, Sendable {
    public var packageName: String
    public var processName: String
    public var pid: Int
    public var sdkInt: Int
    public var agentVersion: String
    public var port: Int

    public init(packageName: String, processName: String, pid: Int, sdkInt: Int, agentVersion: String, port: Int) {
        self.packageName = packageName
        self.processName = processName
        self.pid = pid
        self.sdkInt = sdkInt
        self.agentVersion = agentVersion
        self.port = port
    }
}

public struct LogEntry: Codable, Sendable {
    public var timestampMillis: Int64
    public var level: String
    public var message: String
    public var metadata: [String: MetadataValue]

    public init(timestampMillis: Int64, level: String, message: String, metadata: [String: MetadataValue] = [:]) {
        self.timestampMillis = timestampMillis
        self.level = level
        self.message = message
        self.metadata = metadata
    }

    private enum CodingKeys: String, CodingKey { case timestampMillis, level, message, metadata }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(timestampMillis, forKey: .timestampMillis)
        try c.encode(level, forKey: .level)
        try c.encode(message, forKey: .message)
        if !metadata.isEmpty { try c.encode(metadata, forKey: .metadata) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestampMillis = try c.decode(Int64.self, forKey: .timestampMillis)
        level = try c.decode(String.self, forKey: .level)
        message = try c.decode(String.self, forKey: .message)
        metadata = try c.decodeIfPresent([String: MetadataValue].self, forKey: .metadata) ?? [:]
    }
}

public struct LogBatch: Codable, Sendable {
    public var entries: [LogEntry]
    public init(entries: [LogEntry]) { self.entries = entries }
}

/// A single-capture UI report produced inside the app process: one snapshot,
/// with the semantic tree and compact observation derived from that exact frame.
public struct UiReport: Codable, Sendable {
    public var snapshot: Snapshot
    public var semantics: SemanticTree
    public var compact: CompactObservation

    public init(snapshot: Snapshot, semantics: SemanticTree, compact: CompactObservation) {
        self.snapshot = snapshot
        self.semantics = semantics
        self.compact = compact
    }

    /// Build all report views from one authoritative snapshot.
    public static func from(_ snapshot: Snapshot) -> UiReport {
        UiReport(
            snapshot: snapshot,
            semantics: SemanticTree.build(from: snapshot),
            compact: CompactObservation.from(snapshot)
        )
    }
}

/// A stable target for actions and mutations. Resolution order: testId /
/// resourceId first, then ref, then raw point.
public struct Selector: Codable, Sendable {
    public var testId: String?
    public var resourceId: String?
    public var cssSelector: String?
    public var ref: String?
    public var point: Point?
    public var region: String?

    public init(testId: String? = nil, resourceId: String? = nil, cssSelector: String? = nil, ref: String? = nil, point: Point? = nil, region: String? = nil) {
        self.testId = testId
        self.resourceId = resourceId
        self.cssSelector = cssSelector
        self.ref = ref
        self.point = point
        self.region = region
    }

    public func describe() -> String {
        var base = "<empty>"
        if let testId { base = "testId=\(testId)" }
        else if let resourceId { base = "resourceId=\(resourceId)" }
        else if let cssSelector { base = "css=\(cssSelector)" }
        else if let ref { base = "ref=\(ref)" }
        else if let point { base = "point=\(point.x),\(point.y)" }
        if let region { return "\(base) region=\"\(region)\"" }
        return base
    }
}

public struct MutationRequest: Codable, Sendable {
    public var selector: Selector
    public var property: String
    public var value: MetadataValue

    public init(selector: Selector, property: String, value: MetadataValue) {
        self.selector = selector
        self.property = property
        self.value = value
    }
}

public struct MutationResult: Codable, Sendable {
    public var applied: Bool
    public var ref: String?
    public var previousValue: MetadataValue?
    public var message: String?

    public init(applied: Bool, ref: String? = nil, previousValue: MetadataValue? = nil, message: String? = nil) {
        self.applied = applied
        self.ref = ref
        self.previousValue = previousValue
        self.message = message
    }
}
