import Foundation

/// What the **system channel** saw. Deliberately NOT a `Snapshot` of `Node`s.
///
/// The system channel is an out-of-process XCUITest runner, and it is a different
/// KIND of source from the in-process agent, not a weaker configuration of it:
///
/// - It reaches what the agent structurally cannot — another process's window: a
///   system permission alert, SpringBoard, the app switcher.
/// - It reads far less of what it does reach — one accessibility layer only. No
///   view layer, no Compose semantics, no WebView DOM, no styles, no interaction
///   regions. Measured on an iPhone 13 Pro Max / iOS 26: a system alert came back
///   as 30 readable nodes with exact frames, while a WebView came back with every
///   HTML `id`/`class` empty and no computed style at all.
///
/// Those two facts are why this is its own type. Had these nodes been `Node`s, the
/// fields this channel cannot fill would have arrived EMPTY, and an empty
/// `styleChannels` reads as "the app really set no style" rather than "no channel
/// here can see style" — the exact confusion `Node.styleGaps` exists to prevent.
/// A separate type makes the mistake unrepresentable instead of merely discouraged,
/// and it keeps `NodeKind` (a Swift/Kotlin double-written enum) out of it: Android
/// has neither this channel nor the gap that motivates it.
public struct SystemObservation: Codable, Sendable, Equatable {

    /// Ref of the subtree root, or nil when there was nothing to read — see
    /// `overlayPresent`.
    public var rootRef: String?

    /// Flat ref -> node map, same shape as `Snapshot`'s so a reader's habits carry
    /// over even though the element type does not.
    public var nodes: [String: SystemNode]

    /// Whether a topmost overlay was actually up. `false` is a POSITIVE answer
    /// ("nothing is covering the app right now"), not an absence of one: a caller
    /// that has to infer this from an empty tree will eventually infer it wrong.
    public var overlayPresent: Bool

    /// Set when a node/depth ceiling cut the walk short. Present means "this tree
    /// is partial and here is by how much" — a truncated tree that looks complete
    /// is worse than no tree.
    public var truncation: SystemTruncation?

    /// Always `system-runner`. Carried explicitly so a consumer holding this next
    /// to an agent observation can never mix up which channel produced what.
    public var sourceChannel: String

    /// Which process this reading is ABOUT (a bundle id, `springboard`, …).
    public var targetProcess: String?

    /// True when the runner had vanished and was restarted to serve this request.
    /// It is reported rather than hidden because a restart interrupts whatever was
    /// in the foreground, which is observable interference with the flow under
    /// test — a caller that does not know it happened will attribute it to the app.
    public var runnerRestarted: Bool

    public init(
        rootRef: String? = nil,
        nodes: [String: SystemNode] = [:],
        overlayPresent: Bool,
        truncation: SystemTruncation? = nil,
        sourceChannel: String = SystemObservation.channelName,
        targetProcess: String? = nil,
        runnerRestarted: Bool = false
    ) {
        self.rootRef = rootRef
        self.nodes = nodes
        self.overlayPresent = overlayPresent
        self.truncation = truncation
        self.sourceChannel = sourceChannel
        self.targetProcess = targetProcess
        self.runnerRestarted = runnerRestarted
    }

    public static let channelName = "system-runner"
}

/// How much of the tree was left unread, and against which ceiling.
///
/// Both numbers are carried because "truncated" alone does not tell a caller
/// whether to retry with a narrower target or to give up on this target entirely.
public struct SystemTruncation: Codable, Sendable, Equatable {
    /// Nodes actually returned.
    public var returned: Int
    /// The ceiling that stopped the walk.
    public var limit: Int
    /// Which ceiling it was, so the message can say so.
    public var reason: String

    public init(returned: Int, limit: Int, reason: String) {
        self.returned = returned
        self.limit = limit
        self.reason = reason
    }
}

/// One element as the system channel can see it.
///
/// The absent fields are the point. There is no `isVisible`, no `checked`, no
/// `expanded`, no `isFocusable`, and no style of any kind — not because they were
/// forgotten but because this channel has no honest value for them. Each one is
/// named in `unreadable` instead, so it reads as "this channel cannot see it"
/// rather than as "the app does not have it".
///
/// `hasFocus` is missing for a sharper reason: XCTest exposes it, and it was
/// measured to be `true` for EVERY node of a WebView's content tree. A field that
/// is constantly true is worse than a missing one, because it invites a caller to
/// trust it.
public struct SystemNode: Codable, Sendable, Equatable {
    public var ref: String
    public var parentRef: String?
    public var children: [String]

    /// Role derived from the element type. Coarser than a real class name, which
    /// this channel does not expose — see `unreadable`.
    public var role: SystemRole

    public var label: String?
    public var value: String?
    public var placeholder: String?

    /// The accessibility identifier, when the target sets one. This one DOES come
    /// through, which is why a selector by test id is usable here.
    public var testId: String?

    public var frame: Rect?
    public var isEnabled: Bool

    /// Whether the element can be hit. **Not** a synonym for visibility: an
    /// element can be on screen and not hittable, and this channel has no
    /// visibility signal at all. `isVisible` is listed in `unreadable`.
    public var isHittable: Bool

    /// Properties this node is known to HAVE but which this channel cannot read,
    /// keyed by property name with a short reason. Same contract as
    /// `Node.styleGaps`: an unreachable thing names itself instead of looking
    /// absent. A key here is never also a populated field above.
    public var unreadable: [String: String]

    public init(
        ref: String,
        parentRef: String? = nil,
        children: [String] = [],
        role: SystemRole,
        label: String? = nil,
        value: String? = nil,
        placeholder: String? = nil,
        testId: String? = nil,
        frame: Rect? = nil,
        isEnabled: Bool,
        isHittable: Bool,
        unreadable: [String: String] = SystemNode.channelGaps
    ) {
        self.ref = ref
        self.parentRef = parentRef
        self.children = children
        self.role = role
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.testId = testId
        self.frame = frame
        self.isEnabled = isEnabled
        self.isHittable = isHittable
        self.unreadable = unreadable
    }

    /// The gaps that hold for EVERY node this channel produces, because they are
    /// properties of the channel and not of any one element. Measured, not assumed
    /// — see the per-key reasons.
    public static let channelGaps: [String: String] = [
        "isVisible": "system-channel-has-no-visibility-signal",
        "typeName": "system-channel-exposes-element-type-only",
        "checked": "system-channel-has-no-toggle-state",
        "expanded": "system-channel-has-no-disclosure-state",
        "isFocusable": "system-channel-has-no-focus-channel",
        "isFocused": "system-channel-focus-flag-is-constantly-true",
        "regions": "system-channel-has-no-sub-element-regions",
        "style": "system-channel-has-no-style-channel",
        "domNode": "system-channel-sees-accessibility-only-not-dom",
    ]
}

/// The element roles this channel can name.
///
/// XCTest reports an integer element type, and the mapping is intentionally
/// lossy-but-honest: an unrecognized value becomes `unrecognized(rawValue:)`
/// rather than being dropped or bent into the nearest known role. Dropping it
/// would delete a node that is really on screen; bending it would state a role
/// the platform never claimed. Both are worse than saying "there is something
/// here and I do not have a name for it".
public enum SystemRole: Sendable, Equatable {
    case application
    case window
    case button
    case staticText
    case textField
    case secureTextField
    case image
    case cell
    case alert
    case webView
    case link
    case other
    case unrecognized(rawValue: Int)

    /// Wire spelling. `unrecognized` keeps the raw value visible so a future iOS
    /// adding a type shows up as a diagnosable `unrecognized:71` instead of
    /// silently becoming `other`.
    public var wireName: String {
        switch self {
        case .application: return "application"
        case .window: return "window"
        case .button: return "button"
        case .staticText: return "staticText"
        case .textField: return "textField"
        case .secureTextField: return "secureTextField"
        case .image: return "image"
        case .cell: return "cell"
        case .alert: return "alert"
        case .webView: return "webView"
        case .link: return "link"
        case .other: return "other"
        case .unrecognized(let raw): return "unrecognized:\(raw)"
        }
    }

    /// Map an `XCUIElement.ElementType` raw value. The numbers are XCTest's, kept
    /// here (rather than importing XCTest into the protocol) so the host can decode
    /// a runner's answer without linking the test framework.
    public static func fromElementType(_ raw: Int) -> SystemRole {
        switch raw {
        case 0: return .other
        case 1: return .other        // XCTest's "any"/generic container
        case 2: return .application
        case 4: return .window
        // 5 = sheet, 7 = alert, 8 = dialog. All three mean "a modal the system
        // owns" to a caller here. Measured on iOS 26: a real permission prompt
        // arrives as 7 — the value this table originally got wrong, which surfaced
        // as a diagnosable `unrecognized:7` rather than as a silently wrong role.
        case 5, 7, 8: return .alert
        case 9: return .button
        case 42: return .link
        case 46: return .other       // grouping container
        case 48: return .staticText
        case 49: return .textField
        case 50: return .secureTextField
        case 52: return .other       // text view / editable content
        case 58: return .webView
        case 75: return .cell
        case 82: return .image
        default: return .unrecognized(rawValue: raw)
        }
    }

}

extension SystemRole: Codable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw.hasPrefix("unrecognized:"),
           let n = Int(raw.dropFirst("unrecognized:".count)) {
            self = .unrecognized(rawValue: n)
            return
        }
        switch raw {
        case "application": self = .application
        case "window": self = .window
        case "button": self = .button
        case "staticText": self = .staticText
        case "textField": self = .textField
        case "secureTextField": self = .secureTextField
        case "image": self = .image
        case "cell": self = .cell
        case "alert": self = .alert
        case "webView": self = .webView
        case "link": self = .link
        case "other": self = .other
        default:
            // An unknown SPELLING is itself unrecognized rather than a decode
            // failure: a newer runner talking to an older host should degrade to
            // "something is there", not drop the whole observation.
            self = .unrecognizedSpelling
        }
    }

    /// A role whose SPELLING this build does not know. Distinct from a known-bad
    /// element type only in that there is no number to carry.
    public static let unrecognizedSpelling = SystemRole.unrecognized(rawValue: -1)

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wireName)
    }
}

/// What a caller asked the system channel to read.
public enum SystemReadTarget: Sendable, Equatable {
    /// The one thing currently covering the app under test. The DEFAULT, because
    /// "what is covering me" is the question this channel exists to answer, and
    /// because a full system-layer walk is minutes-expensive.
    case topmostOverlay
    /// The Home screen. Must be asked for explicitly — measured at 300+ nodes.
    case home
    /// A specific installed app's UI.
    case app(bundleId: String)

    public var describe: String {
        switch self {
        case .topmostOverlay: return "topmost-overlay"
        case .home: return "home"
        case .app(let b): return "app:\(b)"
        }
    }
}

/// What a system-channel action did.
///
/// The shape exists to keep one distinction impossible to blur: **dispatched is
/// not the same as effective**. An action that was delivered and changed nothing
/// is a real, common outcome — a tap on an inert patch of Home screen, a button
/// whose handler declined — and reporting it as success would be a verdict this
/// tool has no business issuing.
public struct SystemActionResult: Codable, Sendable, Equatable {
    /// The action reached the system. False only when it was refused before
    /// dispatch (unknown target, out-of-bounds coordinate).
    public var dispatched: Bool

    /// Whether anything observably changed afterwards. `nil` means "not checked",
    /// which is distinct from `false` ("checked, nothing moved").
    public var changed: Bool?

    /// Which process the action was aimed at.
    public var targetProcess: String?

    /// How the target was named, for the evidence line: `label:允许`, `point:12,34`.
    public var via: String

    /// Set when the action was refused: what was asked for, and what was actually
    /// available instead. A refusal that does not say what IS there leaves the
    /// caller guessing.
    public var refusal: String?
    public var available: [String]

    public var runnerRestarted: Bool

    public init(
        dispatched: Bool,
        changed: Bool? = nil,
        targetProcess: String? = nil,
        via: String,
        refusal: String? = nil,
        available: [String] = [],
        runnerRestarted: Bool = false
    ) {
        self.dispatched = dispatched
        self.changed = changed
        self.targetProcess = targetProcess
        self.via = via
        self.refusal = refusal
        self.available = available
        self.runnerRestarted = runnerRestarted
    }

    /// One line of evidence. Never says "succeeded": it says what happened.
    public var describe: String {
        guard dispatched else {
            var s = "refused via=\(via)"
            if let r = refusal { s += " reason=\(r)" }
            if !available.isEmpty { s += " available=[\(available.joined(separator: ", "))]" }
            return s
        }
        var s = "dispatched via=\(via)"
        if let p = targetProcess { s += " process=\(p)" }
        switch changed {
        case .some(true): s += " changed=yes"
        case .some(false): s += " changed=no (dispatched, but nothing observably changed)"
        case .none: s += " changed=unchecked"
        }
        if runnerRestarted { s += " warning:runner-started-mid-command" }
        return s
    }
}
