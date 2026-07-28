import Foundation

// The host's platform-facing domain interface.
//
// Why this exists, and what it replaced. Every command used to be issued through
// one stringly-typed call — `call("uiReport", ["package": pkg])` — returning
// `[String: Any]`. For Android that shape is real: the call crosses a process
// boundary as JSONL (reticle-protocol/helper-rpc.md), and a dictionary is what a
// wire is. But the *transport's* shape had been promoted into the *domain*
// abstraction, so a natively in-host backend (iOS) paid the whole cost of a wire
// it does not have: a 900-line switch over method-name strings, ~46 `as?`
// unpacks, and a misspelled key discovered at runtime on a device rather than at
// compile time on a laptop.
//
// So: `HostBackend` is the domain interface (typed, one method per capability, no
// strings), and `HelperCalling` stays the Android *transport* — used by
// `AndroidBackend`, the resident helperd socket, and the `serve --helper-broker`
// forwarder, all of which genuinely speak JSONL.

/// One platform's implementation of every command the host can issue.
///
/// Implementations: `AndroidBackend` (adapting the Kotlin helper's JSONL RPC) and
/// `IosHelperClient` (natively in-host — `simctl`/`devicectl`, loopback HTTP,
/// CoreSimulator HID). A method a platform cannot serve throws, naming itself.
public protocol HostBackend: AnyObject, Sendable {
    func ping() throws -> PingResult
    func listDevices() throws -> [DeviceSummary]
    func status(_ request: StatusRequest) throws -> StatusResult
    func launch(_ request: AppStartRequest) throws -> RuntimeStartResult
    func inject(_ request: AppStartRequest) throws -> RuntimeStartResult
    func uiReport(_ request: PackageRequest) throws -> UiReportResult
    func screenshot(_ request: ScreenshotRequest) throws -> ScreenshotResult
    func render(_ request: RenderRequest) throws -> RenderResult
    func mutate(_ request: MutateRequest) throws -> MutationOutcome
    func logs(_ request: PackageRequest) throws -> [AppLogEntry]
    func logcat() throws -> [String]
    func act(_ request: ActRequest) throws -> ActOutcome

    /// Releases whatever transport this backend holds. Default no-op: an in-host
    /// backend owns nothing. Lets command dispatch `defer` one teardown.
    func close()
}

public extension HostBackend {
    func close() {}
}

// MARK: - Requests

/// Selector params, in the protocol's own vocabulary rather than CLI flag names.
/// `point` and `alias` are carried even where a command refuses them, so the
/// refusal can name them ("a coordinate always resolves") instead of degrading to
/// a generic "needs a predicate".
public struct HostSelector: Sendable, Equatable {
    public var testId: String?
    public var resourceId: String?
    public var cssSelector: String?
    public var ref: String?
    public var point: String?
    public var label: String?
    public var region: String?
    public var alias: String?

    public init(
        testId: String? = nil, resourceId: String? = nil, cssSelector: String? = nil,
        ref: String? = nil, point: String? = nil, label: String? = nil,
        region: String? = nil, alias: String? = nil
    ) {
        self.testId = testId
        self.resourceId = resourceId
        self.cssSelector = cssSelector
        self.ref = ref
        self.point = point
        self.label = label
        self.region = region
        self.alias = alias
    }

    public var isEmpty: Bool {
        testId == nil && resourceId == nil && cssSelector == nil && ref == nil
            && point == nil && label == nil && region == nil && alias == nil
    }

    /// The wire keys, for the JSONL transport. Only `AndroidBackend` needs this.
    public var wireParams: [String: Any] {
        var out: [String: Any] = [:]
        if let testId { out["testId"] = testId }
        if let resourceId { out["resourceId"] = resourceId }
        if let cssSelector { out["css"] = cssSelector }
        if let ref { out["ref"] = ref }
        if let point { out["point"] = point }
        if let label { out["label"] = label }
        if let region { out["region"] = region }
        if let alias { out["alias"] = alias }
        return out
    }
}

public struct PackageRequest: Sendable {
    public let package: String
    public init(package: String) { self.package = package }
}

public struct StatusRequest: Sendable {
    public let package: String
    public init(package: String) { self.package = package }
}

/// `launch` and `inject` take the same shape: which app, and (for `inject`) which
/// injectable — a payload dex on Android, a dylib on iOS.
public struct AppStartRequest: Sendable {
    public let package: String
    public let payload: String?
    /// `app inject` only: mark the app as being debugged for the injection, so AMS
    /// relaxes the input-dispatch ANR verdict while JDWP holds the main thread
    /// suspended. Opt-in because setting the debug app force-stops the target — the
    /// app is relaunched and the screen it was on is lost.
    public let restartUnderDebugger: Bool
    public init(package: String, payload: String? = nil, restartUnderDebugger: Bool = false) {
        self.package = package
        self.payload = payload
        self.restartUnderDebugger = restartUnderDebugger
    }
}

public struct ScreenshotRequest: Sendable {
    public let package: String?
    public init(package: String?) { self.package = package }
}

public struct RenderRequest: Sendable {
    public let view: String
    public let snapshotPath: String
    public let depth: Int?
    public let selector: HostSelector
    /// Present only so `outline` can write its alias cache for this package.
    public let package: String?

    public init(view: String, snapshotPath: String, depth: Int? = nil,
                selector: HostSelector = .init(), package: String? = nil) {
        self.view = view
        self.snapshotPath = snapshotPath
        self.depth = depth
        self.selector = selector
        self.package = package
    }
}

public struct MutateRequest: Sendable {
    public let package: String
    public let property: String
    public let value: String
    public let selector: HostSelector

    public init(package: String, property: String, value: String, selector: HostSelector) {
        self.package = package
        self.property = property
        self.value = value
        self.selector = selector
    }
}

/// One gesture, with every modifier the command surface accepts.
///
/// `@unchecked Sendable` because of the `[String: Any]` escape hatches below (the
/// forwarded batch keys here, the raw trees in `UiReportResult`, the raw result in
/// `ActOutcome`). Each of those is JSON that this process only ever moves — parsed
/// once, never mutated, never shared across tasks — so the value is in fact immutable;
/// `Any` is simply outside what the compiler can prove.
///
/// Deliberately one struct rather than a per-gesture enum: `act batch` builds
/// these from user JSON where the gesture is a data field, and the modifiers
/// (`verify`, `trace*`, `settle*`) apply across gestures. A gesture that ignores a
/// modifier says so in its result (e.g. `settleSkipped`) rather than failing.
public struct ActRequest: @unchecked Sendable {
    public var gesture: String
    public var package: String
    public var selector: HostSelector
    /// Gesture-specific inputs: swipe/drag `from`/`to`/`duration`, `type`'s text,
    /// `scroll-to`'s container/direction/maxSwipes, `wait`'s predicate fields.
    public var from: String?
    public var to: String?
    public var duration: String?
    public var text: String?
    public var container: String?
    public var direction: String?
    public var maxSwipes: String?
    public var submit: Bool = false
    public var settle: Bool = false
    /// Opt OUT of the pre-dispatch confirm a selector tap now does by default.
    /// The confirm exists because a rect resolved before an intervening relayout
    /// sends the touch to the neighbouring control while reporting success; this
    /// is for a caller who has measured that cost and wants the single-read
    /// dispatch back.
    public var noSettle: Bool = false
    public var settleTimeoutMs: Int?
    /// `wait` only. `textContains` is named apart from `text` on the wire so a
    /// batch step can never be read as a `type`.
    public var waitFor: String?
    public var waitGone: Bool = false
    public var waitIdle: Bool = false
    public var textContains: String?
    public var timeoutMs: Int?
    public var quietMs: Int?
    public var verify: String?
    public var verifyTimeoutMs: Int?
    public var traceOutput: String?
    public var traceAuto: Bool = false
    public var traceDelayMs: Int?
    /// Keys a batch step carried that are not part of this shape. Forwarded
    /// verbatim over the wire, so a step written against a newer helper still
    /// reaches it, and named here so "silently dropped" is not the alternative.
    public var extraWireParams: [String: Any] = [:]

    public init(gesture: String, package: String, selector: HostSelector = .init()) {
        self.gesture = gesture
        self.package = package
        self.selector = selector
    }

    public var wireParams: [String: Any] {
        var out: [String: Any] = extraWireParams
        out["gesture"] = gesture
        out["package"] = package
        for (key, value) in selector.wireParams { out[key] = value }
        if let from { out["from"] = from }
        if let to { out["to"] = to }
        if let duration { out["duration"] = duration }
        if let text { out["text"] = text }
        if let container { out["container"] = container }
        if let direction { out["direction"] = direction }
        if let maxSwipes { out["maxSwipes"] = maxSwipes }
        if submit { out["submit"] = true }
        if settle { out["settle"] = true }
        if noSettle { out["noSettle"] = true }
        if let settleTimeoutMs { out["settleTimeoutMs"] = settleTimeoutMs }
        if let waitFor { out["for"] = waitFor }
        if waitGone { out["gone"] = true }
        if waitIdle { out["idle"] = true }
        if let textContains { out["textContains"] = textContains }
        if let timeoutMs { out["timeoutMs"] = timeoutMs }
        if let quietMs { out["quietMs"] = quietMs }
        if let verify { out["verify"] = verify }
        if let verifyTimeoutMs { out["verifyTimeoutMs"] = verifyTimeoutMs }
        if let traceOutput { out["traceOutput"] = traceOutput }
        if traceAuto { out["traceAuto"] = true }
        if let traceDelayMs { out["traceDelayMs"] = traceDelayMs }
        return out
    }
}

// MARK: - Results

public struct PingResult: Sendable {
    public let version: String
    public init(version: String) { self.version = version }
}

public struct DeviceSummary: Sendable {
    public let serial: String
    public let state: String
    /// iOS only: the simulator's name and runtime, absent for an adb device.
    public let name: String?
    public let runtime: String?

    public init(serial: String, state: String, name: String? = nil, runtime: String? = nil) {
        self.serial = serial
        self.state = state
        self.name = name
        self.runtime = runtime
    }

    public var jsonObject: [String: Any] {
        var out: [String: Any] = ["serial": serial, "state": state]
        if let name { out["name"] = name }
        if let runtime { out["runtime"] = runtime }
        return out
    }
}

public struct StatusResult: Sendable {
    public let devices: [DeviceSummary]
    public let running: Bool
    public let pid: Int?
    /// `healthy` / `conflict` / `unreachable` / `unresponsive` / `foreign`.
    public let runtime: String?
    public let port: Int?
    public let agentVersion: String?

    public init(devices: [DeviceSummary], running: Bool, pid: Int?, runtime: String?,
                port: Int? = nil, agentVersion: String? = nil) {
        self.devices = devices
        self.running = running
        self.pid = pid
        self.runtime = runtime
        self.port = port
        self.agentVersion = agentVersion
    }

    public var jsonObject: [String: Any] {
        var out: [String: Any] = ["devices": devices.map(\.jsonObject), "running": running]
        if let pid { out["pid"] = pid }
        if let runtime { out["runtime"] = runtime }
        if let port { out["port"] = port }
        if let agentVersion { out["agentVersion"] = agentVersion }
        return out
    }
}

public struct RuntimeStartResult: Sendable {
    public let packageName: String
    public let pid: Int?
    public let port: Int?
    public let agentVersion: String?
    public let via: String?

    public init(packageName: String, pid: Int?, port: Int?, agentVersion: String?, via: String? = nil) {
        self.packageName = packageName
        self.pid = pid
        self.port = port
        self.agentVersion = agentVersion
        self.via = via
    }

    public var jsonObject: [String: Any] {
        var out: [String: Any] = ["packageName": packageName]
        if let pid { out["pid"] = pid }
        if let port { out["port"] = port }
        if let agentVersion { out["agentVersion"] = agentVersion }
        if let via { out["via"] = via }
        return out
    }
}

/// The three trees, still as raw JSON: the host writes them to disk byte-for-byte
/// and never inspects them, so decoding and re-encoding would only risk changing
/// what the agent captured. The counts are what commands actually read.
public struct UiReportResult: @unchecked Sendable {
    public let nodeCount: Int?
    public let compactItemCount: Int?
    public let semanticNodeCount: Int?
    public let trees: [String: Any]

    public init(nodeCount: Int?, compactItemCount: Int?, semanticNodeCount: Int?, trees: [String: Any]) {
        self.nodeCount = nodeCount
        self.compactItemCount = compactItemCount
        self.semanticNodeCount = semanticNodeCount
        self.trees = trees
    }
}

public struct ScreenshotResult: Sendable {
    public let pngBase64: String
    public let via: String?
    /// What this picture is known to be missing (`pixels:unavailable`,
    /// `screencap:blank`), so `ui screenshot` can print its `degraded:` line.
    public let degraded: [String]

    public init(pngBase64: String, via: String?, degraded: [String] = []) {
        self.pngBase64 = pngBase64
        self.via = via
        self.degraded = degraded
    }
}

public struct RenderResult: Sendable {
    public let text: String
    public init(text: String) { self.text = text }
}

public struct MutationOutcome: Sendable {
    public let applied: Bool
    public let ref: String?
    public let previousValue: String?

    public init(applied: Bool, ref: String?, previousValue: String?) {
        self.applied = applied
        self.ref = ref
        self.previousValue = previousValue
    }

    public var jsonObject: [String: Any] {
        var out: [String: Any] = ["applied": applied]
        if let ref { out["ref"] = ref }
        if let previousValue { out["previousValue"] = previousValue }
        return out
    }
}

public struct AppLogEntry: Sendable {
    public let level: String
    public let message: String

    public init(level: String, message: String) {
        self.level = level
        self.message = message
    }

    public var jsonObject: [String: Any] { ["level": level, "message": message] }
}

/// The outcome of one gesture.
///
/// The fields are the ones the host **decides** on: a `wait`'s three-state
/// outcome (and `--strict`'s exit-code projection), whether a batch gate passed,
/// whether a trace should be published to `reticle serve`. Those were the reads
/// that used to be `as? String` against a key spelled in two places.
///
/// `raw` keeps the backend's whole result object, and printing goes through it on
/// purpose. This is an evidence tool: a gesture reports gesture-specific facts
/// (`settled`, `submit.via`, `wasVisible`, `settleSkipped`, …), and a closed
/// struct would mean a new fact cannot reach the user until the host is edited
/// too. So: typed where a decision is made, open where it is displayed.
public struct ActOutcome: @unchecked Sendable {
    public let raw: [String: Any]

    public init(raw: [String: Any]) { self.raw = raw }

    public var gesture: String? { raw["gesture"] as? String }
    /// `wait` only: `resolved` / `absent` / `unknowable`.
    public var outcome: String? { raw["outcome"] as? String }
    public var predicate: String? { raw["predicate"] as? String }
    public var reasons: [String] { (raw["reasons"] as? [Any])?.map { "\($0)" } ?? [] }
    public var verify: [String: Any]? { raw["verify"] as? [String: Any] }
    public var trace: [String: Any]? { raw["trace"] as? [String: Any] }

    /// The result minus the two sub-objects that have their own printers.
    public var displayFields: [String: Any] {
        raw.filter { $0.key != "verify" && $0.key != "trace" }
    }
}

public extension RenderRequest {
    /// Sentinel `snapshotPath` meaning "capture the live tree instead of reading a
    /// file". A sentinel rather than a `live: Bool` because the Android helper's
    /// `render` takes a path and this keeps one field authoritative about where the
    /// snapshot comes from — two fields could disagree.
    static let liveSnapshotPath = "@live"
}

public extension ActRequest {
    /// Builds a request from one `act batch --file` step.
    ///
    /// A batch step is user JSON whose keys are the protocol's own field names, so
    /// this is where untyped input legitimately enters. Keys this shape knows become
    /// typed fields; anything else is carried in `extraWireParams` rather than
    /// dropped — a step written against a newer helper than this host still reaches
    /// it, which is the property the old pass-the-dictionary-through design had for
    /// free and a closed struct would have quietly removed.
    static func fromBatchStep(_ step: [String: Any], defaultPackage: String) -> ActRequest {
        var request = ActRequest(
            gesture: step["gesture"] as? String ?? "",
            package: step["package"] as? String ?? defaultPackage
        )
        var extra = step
        func take(_ key: String) -> Any? {
            let value = extra[key]
            extra.removeValue(forKey: key)
            return value
        }
        func string(_ key: String) -> String? {
            guard let value = take(key) else { return nil }
            if let s = value as? String { return s }
            return "\(value)"
        }
        func flag(_ key: String) -> Bool {
            switch take(key) {
            case let b as Bool: return b
            case let s as String: return s == "true" || s == "1"
            case let n as NSNumber: return n.boolValue
            default: return false
            }
        }
        func int(_ key: String) -> Int? {
            switch take(key) {
            case let i as Int: return i
            case let n as NSNumber: return n.intValue
            case let s as String: return Int(s)
            default: return nil
            }
        }
        _ = take("gesture")
        _ = take("package")
        request.selector = HostSelector(
            testId: string("testId"), resourceId: string("resourceId"),
            cssSelector: string("css"), ref: string("ref"), point: string("point"),
            label: string("label"), region: string("region"), alias: string("alias")
        )
        request.from = string("from")
        request.to = string("to")
        request.duration = string("duration")
        request.text = string("text")
        request.container = string("container")
        request.direction = string("direction")
        request.maxSwipes = string("maxSwipes")
        request.submit = flag("submit")
        request.settle = flag("settle")
        request.noSettle = flag("noSettle")
        request.settleTimeoutMs = int("settleTimeoutMs")
        request.waitFor = string("for")
        request.waitGone = flag("gone")
        request.waitIdle = flag("idle")
        request.textContains = string("textContains")
        request.timeoutMs = int("timeoutMs")
        request.quietMs = int("quietMs")
        request.verify = string("verify")
        request.verifyTimeoutMs = int("verifyTimeoutMs")
        request.traceOutput = string("traceOutput")
        request.traceAuto = flag("traceAuto")
        request.traceDelayMs = int("traceDelayMs")
        // Host-side step controls, consumed by the batch runner and never sent.
        _ = take("strict")
        _ = take("delayMs")
        request.extraWireParams = extra
        return request
    }
}
