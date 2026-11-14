import Foundation
import ReticleHostAct
import ReticleHostIos
import ReticleHostShared
import ReticleProtocol

/// Android `act`, orchestrated in the host.
///
/// The helper captures (`snapshot`, with a screenshot for a trace side) and
/// dispatches (`input`, `hideKeyboard`); every decision is made here, with the same
/// shared code iOS uses: resolution and the settle confirm (`ActTap`), the tap's
/// evidence, `--verify` (`ActVerify`), the trace package (`ActionTraceWriter`). The
/// envelope — verify, trace, the Toast Queue watch — wraps EVERY gesture, including
/// the three the helper still runs itself (`scroll-to`, `wheel`, `type`), which are
/// sent its `act` without any envelope key.
extension AndroidBackend {
    /// Gestures whose body runs here.
    static let hostGestures: Set<String> = ["tap", "swipe", "drag", "hide-keyboard", "hideKeyboard"]
    /// Gestures whose body still runs in the helper's `act`.
    static let helperGestures: Set<String> = ["scroll-to", "scrollTo", "wheel", "type"]
    /// Request keys that belong to the envelope, never forwarded to the helper.
    static let envelopeKeys = ["verify", "verifyTimeoutMs", "traceOutput", "traceAuto", "traceDelayMs", "noToastProbe"]

    func act(_ request: ActRequest) async throws -> ActOutcome {
        if request.gesture == "wait" { return ActOutcome(raw: try await wait(request)) }
        let gesture = request.gesture
        // `activate` is iOS-only and exists BECAUSE iOS lacks what Android has: it
        // drives a control in-process, the only input path on a real iOS device.
        // Android synthesizes real input, so there is nothing to fall back FROM.
        if gesture == "activate" {
            throw HelperError(
                "act activate is iOS-only: it activates a control in-process because a real iOS device "
                    + "exposes no host-reachable HID surface. Android synthesizes real input instead — use "
                    + "`act tap` with the same selector (`--css` included), which dispatches an actual touch."
            )
        }
        guard Self.hostGestures.contains(gesture) || Self.helperGestures.contains(gesture) else {
            throw HelperError("unknown act gesture '\(gesture)' (tap/swipe/drag/scroll-to/wheel/type/hide-keyboard/wait; "
                + "activate is iOS-only)")
        }
        let params = request.wireParams
        let alias = try request.selector.alias.map { name in
            (name, try OutlineAliasCache.resolve(name, serial: serial, package: request.package, home: aliasHome))
        }
        let snapshots = AndroidSnapshots(transport, package: request.package)
        let fetch: SnapshotFetch = { try snapshots.fetch() }
        let watch = try ActVerify.watchSelector(params)

        // The trace's pre-action side. A tap reuses its snapshot as its first
        // resolution, so tracing (on by default, the session trace) costs no extra
        // read. An automatic session trace is best-effort: a runtime that cannot
        // answer drops the trace, not the action — unless `--verify` needs it too.
        var tracer: ActionTraceWriter?
        var traceBefore: TraceCapture?
        if let root = request.traceOutput {
            do {
                traceBefore = try snapshots.capture(screenshotTo: ActionTraceWriter.stagedScreenshot())
                tracer = ActionTraceWriter(
                    root: URL(fileURLWithPath: root), packageName: request.package,
                    recordedParams: ActionTraceParamNames.capture(from: params),
                    capture: { try? snapshots.capture(screenshotTo: $0) }
                )
            } catch {
                if !request.traceAuto || watch != nil { throw error }
            }
        }
        var verifyBefore: ActVerify.State?
        if let watch { verifyBefore = await ActVerify.capture(watch, fetch: fetch) }
        // A text toast is in no window of this app, so an action answered by one
        // otherwise reads as `0 change(s)` — the signal for a gesture that hit
        // nothing. Best-effort: a watch that cannot start never fails the action.
        let toastToken = request.noToastProbe ? nil
            : (try? transport.call(.toastWatch, ["op": "start", "package": request.package]))?["token"] as? String

        var result: [String: Any]
        var target: SelectorResolution.Resolved?
        do {
            switch gesture {
            case "tap":
                (result, target) = try await tap(params, alias: alias, first: traceBefore?.snapshot, fetch: fetch)
            case "swipe", "drag":
                result = try swipe(request)
            case "hide-keyboard", "hideKeyboard":
                result = try transport.call(.hideKeyboard, ["package": request.package])
            default:
                var forward = params
                for key in Self.envelopeKeys { forward.removeValue(forKey: key) }
                if let (_, entry) = alias {
                    forward["aliasEntry"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry))
                }
                result = try transport.call(.act, forward)
            }
        } catch {
            if let toastToken { _ = try? transport.call(.toastWatch, ["op": "stop", "token": toastToken]) }
            throw error
        }

        var verify: [String: Any]?
        if let watch, let verifyBefore {
            verify = await ActVerify.poll(watch, before: verifyBefore, params: params, fetch: fetch)
        }
        // Merged before the trace is written so the toast is IN that step's manifest
        // — the step that says "no observable change" must also say the app answered
        // out of tree.
        if let toastToken, let toasts = (try? transport.call(.toastWatch, ["op": "stop", "token": toastToken]))?["toasts"]
            as? [[String: Any]], let first = toasts.first {
            result["toast"] = first["summary"]
            result["toastKind"] = first["kind"]
            if let duration = first["duration"] { result["toastDuration"] = duration }
            if toasts.count > 1 { result["toastCount"] = toasts.count }
        }
        var out = result
        if let tracer, let traceBefore {
            out["trace"] = try await tracer.write(
                gesture: gesture, selector: ActionTraceWriter.selector(params),
                targetPoint: target?.point, targetSource: target?.source, targetRef: target?.ref,
                result: result.mapValues(ActionTraceWriter.traceString), before: traceBefore,
                // A verify poll already waited for the screen to change.
                settleMs: verify == nil ? (request.traceDelayMs ?? 250) : 0
            )
        }
        if let verify { out["verify"] = verify }
        return ActOutcome(raw: out)
    }

    /// A tap: aim (resolve, then confirm the point held still), judge, dispatch, and
    /// ask the page where a DOM tap landed.
    private func tap(
        _ params: [String: Any], alias: (String, Outline.Entry)?, first: Snapshot?, fetch: SnapshotFetch
    ) async throws -> ([String: Any], SelectorResolution.Resolved) {
        let rawPoint = params["point"] != nil
        let resolve: (Snapshot) throws -> SelectorResolution.Resolved
        if let (name, entry) = alias {
            // The cache records where the node WAS; the live tree says where it is.
            // The cached frame is the fallback when the node is gone.
            resolve = { snapshot in
                if let node = AliasMatch.live(snapshot, entry), let frame = node.frame {
                    return .init(point: Point(x: frame.centerX, y: frame.centerY), source: "outline:\(name)->live", ref: node.ref)
                }
                return .init(point: Point(x: entry.frame.centerX, y: entry.frame.centerY),
                             source: "outline:\(name) (cached frame)", ref: entry.ref)
            }
        } else {
            resolve = { try ActTargeting.resolveTarget(params, snapshot: $0) }
        }
        let snapshot: Snapshot
        do {
            if let first { snapshot = first } else { snapshot = try await fetch() }
        } catch {
            // A selector needs the tree; a typed coordinate or a cached alias frame
            // does not, so those still go out — with no evidence but the admission.
            guard rawPoint || alias != nil else { throw error }
            let blind: SelectorResolution.Resolved
            if let (name, entry) = alias {
                blind = .init(point: Point(x: entry.frame.centerX, y: entry.frame.centerY),
                              source: "outline:\(name) (cached frame)", ref: entry.ref)
            } else {
                let (x, y) = try Self.parseXY(params["point"] as? String, "tap needs a point")
                blind = .init(point: Point(x: Double(x), y: Double(y)), source: "point", ref: nil)
            }
            var result = try dispatchTap(blind.point)
            result["source"] = blind.source
            if let ref = blind.ref { result["ref"] = ref }
            if rawPoint {
                result["coverage"] = ScreenCoverage.unavailable(
                    x: blind.point.x, y: blind.point.y,
                    why: "the tree could not be read at dispatch time (\(error))"
                ).jsonObject
            }
            return (result, blind)
        }
        let aim = try await ActTap.aim(params, first: snapshot, resolve: resolve, fetch: fetch)
        if ProcessInfo.processInfo.environment["RETICLE_DEBUG"] == "1" {
            FileHandle.standardError.write(Data("reticle: resolved via \(aim.target.source) -> ref=\(aim.target.ref ?? "nil")\n".utf8))
        }
        var result = try dispatchTap(aim.target.point)
        // NSNumber booleans print as `1`/`0`, the form `settled=1` callers grep for.
        result.merge(ActTap.evidence(aim, rawPoint: rawPoint, bool: { NSNumber(value: $0) })) { _, new in new }
        // Asked AFTER the touch: the page's own record of where it went. An alias
        // names no selector to re-find it by, so it has none to ask about.
        if !rawPoint, alias == nil, let landed = await ActTargeting.domTapLanding(
            params, target: aim.target, dispatched: aim.snapshot, fetch: fetch) {
            result["landed"] = landed
        }
        return (result, aim.target)
    }

    private func dispatchTap(_ point: Point) throws -> [String: Any] {
        let x = Int(point.x), y = Int(point.y)
        try transport.call(.input, ["kind": "tap", "x": x, "y": y])
        return ["gesture": "tap", "x": x, "y": y]
    }

    private func swipe(_ request: ActRequest) throws -> [String: Any] {
        let gesture = request.gesture
        let (fx, fy) = try Self.parseXY(request.from, "\(gesture) needs 'from'")
        let (tx, ty) = try Self.parseXY(request.to, "\(gesture) needs 'to'")
        let duration = request.duration.flatMap { Int($0) } ?? (gesture == "drag" ? 1000 : 300)
        try transport.call(.input, ["kind": gesture, "from": "\(fx),\(fy)", "to": "\(tx),\(ty)", "durationMs": duration])
        return ["gesture": gesture, "from": "\(fx),\(fy)", "to": "\(tx),\(ty)", "durationMs": duration]
    }

    /// `x,y` in whole pixels, as `adb shell input` takes them.
    static func parseXY(_ value: String?, _ missing: String) throws -> (Int, Int) {
        guard let value else { throw HelperError(missing) }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw HelperError("expected x,y but got '\(value)'") }
        guard let x = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
            throw HelperError("expected numeric x,y but got '\(value)'")
        }
        return (x, y)
    }

    /// `act wait` runs here, over the helper's `snapshot` primitive — the same
    /// `WaitRunner` iOS uses, so there is one poll loop and one classifier. The
    /// first fetch probes the runtime (health + pid identity); the polls after it
    /// do not. An RPC failure mid-wait is thrown, never folded into `unknowable`:
    /// that outcome means "this state could not be seen", not "the tool broke".
    /// Like iOS, a wait honours `--verify` but writes no trace.
    private func wait(_ request: ActRequest) async throws -> [String: Any] {
        let params = request.wireParams
        let predicate = try WaitRunner.predicate(from: params)
        let snapshots = AndroidSnapshots(transport, package: request.package)
        let fetch: SnapshotFetch = { try snapshots.fetch() }
        let run = {
            try await WaitRunner(fetch: fetch).run(
                predicate: predicate,
                timeoutMs: request.timeoutMs ?? WaitSchedule.defaultTimeoutMs,
                quietMs: request.quietMs ?? WaitSchedule.defaultQuietMs
            )
        }
        guard let watch = try ActVerify.watchSelector(params) else { return try await run() }
        let before = await ActVerify.capture(watch, fetch: fetch)
        var result = try await run()
        result["verify"] = await ActVerify.poll(watch, before: before, params: params, fetch: fetch)
        return result
    }
}

/// The helper's `snapshot` primitive for one action: the first read probes the
/// runtime (health + pid identity), every later one skips that round trip.
final class AndroidSnapshots: @unchecked Sendable {
    private let transport: HelperCalling
    private let package: String
    private let lock = NSLock()
    private var probed = false

    init(_ transport: HelperCalling, package: String) {
        self.transport = transport
        self.package = package
    }

    func fetch() throws -> Snapshot {
        try decode(call([:]))
    }

    /// A trace side: the snapshot verbatim plus a screenshot the helper writes to
    /// `screenshotTo` — a file on this machine, never base64 down the pipe.
    func capture(screenshotTo: URL) throws -> TraceCapture {
        let r = try call(["screenshotPath": screenshotTo.path])
        guard let tree = r["snapshot"] else { throw HelperError("snapshot returned no snapshot") }
        let data = try JSONSerialization.data(withJSONObject: tree, options: [.sortedKeys, .withoutEscapingSlashes])
        let shot = (r["screenshot"] as? Bool) == true ? screenshotTo : nil
        return TraceCapture(snapshotJSON: data, snapshot: try SnapshotRender.decode(data), screenshot: shot)
    }

    private func call(_ extra: [String: Any]) throws -> [String: Any] {
        lock.lock()
        let probe = !probed
        probed = true
        lock.unlock()
        var params = extra
        params["package"] = package
        params["probe"] = probe
        return try transport.call(.snapshot, params)
    }

    private func decode(_ r: [String: Any]) throws -> Snapshot {
        guard let tree = r["snapshot"] else { throw HelperError("snapshot returned no snapshot") }
        return try SnapshotRender.decode(JSONSerialization.data(withJSONObject: tree))
    }
}
