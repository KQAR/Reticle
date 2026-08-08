import Foundation

/// Wire endpoints shared by the in-app server and the host. Mirrors
/// reticle-core's `Endpoints` — with two deliberate asymmetries, because the
/// underlying platform affordance exists on one side only:
///
/// - `activate` (`/activate`) is **iOS-only**. It has no Android counterpart:
///   there, host-side HID synthesis reaches a real device, so an in-process
///   activation path is not needed.
/// - `typeText` (`/type`) is **iOS-only**, for the same reason as `activate`:
///   a real device has no host-reachable HID keyboard, so the text is inserted
///   from inside the app through UIKit's own text-input pipeline.
/// - `/editor-action` is **Android-only** (`Endpoints.EDITOR_ACTION` in
///   reticle-core, absent here). It drives `TextView.onEditorAction()`; the iOS
///   analogue is not a separate endpoint but `typeText`'s `submit` flag, which
///   fires the return key's action in-process (`textFieldShouldReturn` +
///   `.editingDidEndOnExit`). On a simulator `act type --submit` still goes
///   through the HID return key.
///
/// Anything else in either list without a twin is drift, not design.
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

    /// iOS-only (no Android counterpart — see the type doc).
    /// In-process control activation (POST, body: ActivationRequest). The agent
    /// resolves the selector to a control and fires its action from *inside* the
    /// app, so it works on a real device where host-side HID synthesis cannot
    /// reach — the on-device analogue of a tap. Limited to activatable targets.
    public static let activate = "/activate"

    /// iOS-only (no Android counterpart — see the type doc).
    /// In-process text entry (POST, body: TypeTextRequest). The agent focuses the
    /// resolved field and inserts the text through `UIKeyInput.insertText` — the
    /// same entry point the system keyboard uses, so delegates, `.editingChanged`
    /// and SwiftUI bindings all fire. This is the on-device analogue of `act type`,
    /// where host-side HID key synthesis cannot reach.
    public static let typeText = "/type"

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

/// Three-state, for the same reason `WaitVerdict` is: the middle state is the
/// point. Collapsing it into `refused` is how an observer lies — measured on an
/// iPhone 13 Pro Max / iOS 26, `UITextView.accessibilityActivate()` OPENS the
/// link it contains (the delegate's `shouldInteractWith` runs) and returns
/// `false` anyway, so a reader that trusts the Bool reports "nothing happened"
/// about a screen that has already navigated.
public enum ActivationOutcome: String, Codable, Sendable {
    /// Dispatched, and the target said so.
    case activated
    /// Dispatched, and the target answered `false` — which UIKit also does for
    /// activations it PERFORMED. Nothing in-process can tell the two apart, so
    /// the caller has to look: `--verify` / `--trace-output` (which run for this
    /// outcome) or a fresh observation.
    case unconfirmed
    /// Nothing was dispatched — no node matched, or the resolved target has no
    /// activation surface at all (a text-range region, a plain view).
    case refused
}

/// Result of an in-process activation. `activated` is true only for
/// `outcome == .activated`; see `ActivationOutcome` for why `false` is two
/// different answers and why they must not be merged.
public struct ActivationResult: Codable, Sendable {
    public var activated: Bool
    public var ref: String?
    public var typeName: String?
    public var via: String?
    public var message: String?
    /// Absent from an agent that predates the three-state answer; read it
    /// through `resolvedOutcome`, which falls back to the old two-state meaning.
    public var outcome: ActivationOutcome?

    public init(activated: Bool, ref: String? = nil, typeName: String? = nil, via: String? = nil,
                message: String? = nil, outcome: ActivationOutcome? = nil) {
        self.activated = activated
        self.ref = ref
        self.typeName = typeName
        self.via = via
        self.message = message
        self.outcome = outcome
    }

    /// The outcome, with the pre-three-state fallback applied: an older agent
    /// reporting `activated=false` meant "refused", which is what it said then.
    public var resolvedOutcome: ActivationOutcome {
        outcome ?? (activated ? .activated : .refused)
    }
}

/// Request to type into a field from inside the app (the on-device "type").
///
/// `selector` is optional: with none, the text goes to whatever holds focus —
/// the same rule the HID path follows. The host resolves a `--label` / region
/// selector to a `ref` before sending, so the agent only ever matches by
/// `testId` / `ref` (its own resolver has no label channel).
public struct TypeTextRequest: Codable, Sendable {
    public var selector: Selector?
    public var text: String
    /// Empty the field before typing, and prove it is empty in the result.
    public var clear: Bool
    /// Fire the return key's action after the text lands.
    public var submit: Bool
    /// Gap between characters, for a field whose formatter drops keystrokes it
    /// receives in one burst (`act type --type-delay`).
    public var perCharDelayMs: Int?

    public init(selector: Selector? = nil, text: String, clear: Bool = false,
                submit: Bool = false, perCharDelayMs: Int? = nil) {
        self.selector = selector
        self.text = text
        self.clear = clear
        self.submit = submit
        self.perCharDelayMs = perCharDelayMs
    }
}

/// What `--clear` did in-process, and whether the field is provably empty.
/// The iOS agent's twin of the host-side `ClearOutcome` on the HID path.
public struct TypeClearOutcome: Codable, Sendable {
    public var emptied: Bool
    public var before: String?
    public var after: String?
    public var deletes: Int
    public var unavailable: String?

    public init(emptied: Bool, before: String? = nil, after: String? = nil,
                deletes: Int = 0, unavailable: String? = nil) {
        self.emptied = emptied
        self.before = before
        self.after = after
        self.deletes = deletes
        self.unavailable = unavailable
    }
}

/// Result of in-process typing. `typed` is false with a `message` when no
/// typeable field could be resolved or focused — Reticle never reports text it
/// did not land. `before`/`after` are the field read back around the insert
/// (masked for a secure field, as everywhere else).
public struct TypeTextResult: Codable, Sendable {
    public var typed: Bool
    public var ref: String?
    public var typeName: String?
    public var via: String?
    public var before: String?
    public var after: String?
    public var secure: Bool?
    public var cleared: TypeClearOutcome?
    /// How the return key's action was fired, when `submit` was asked for.
    public var submitted: String?
    public var message: String?

    public init(typed: Bool, ref: String? = nil, typeName: String? = nil, via: String? = nil,
                before: String? = nil, after: String? = nil, secure: Bool? = nil,
                cleared: TypeClearOutcome? = nil, submitted: String? = nil, message: String? = nil) {
        self.typed = typed
        self.ref = ref
        self.typeName = typeName
        self.via = via
        self.before = before
        self.after = after
        self.secure = secure
        self.cleared = cleared
        self.submitted = submitted
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
    /// Visible text or a11y label, for framework controls with no stable id
    /// (Spinner rows, PopupMenu items, alert buttons). Exact match first, then
    /// substring; ambiguity is an error, never a silent first match.
    public var label: String?
    public var region: String?

    public init(testId: String? = nil, resourceId: String? = nil, cssSelector: String? = nil, ref: String? = nil, point: Point? = nil, label: String? = nil, region: String? = nil) {
        self.testId = testId
        self.resourceId = resourceId
        self.cssSelector = cssSelector
        self.ref = ref
        self.point = point
        self.label = label
        self.region = region
    }

    public func describe() -> String {
        var base = "<empty>"
        if let testId { base = "testId=\(testId)" }
        else if let resourceId { base = "resourceId=\(resourceId)" }
        else if let cssSelector { base = "css=\(cssSelector)" }
        else if let ref { base = "ref=\(ref)" }
        else if let point { base = "point=\(point.x),\(point.y)" }
        else if let label { base = "label=\(label)" }
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
