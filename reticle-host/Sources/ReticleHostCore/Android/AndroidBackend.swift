import Foundation
import ReticleHostAct
import ReticleHostIos
import ReticleProtocol

/// The Android `HostBackend`: typed calls in, JSONL RPC out.
///
/// This is the **only** place the helper's method names and parameter keys are
/// spelled, and the only place its `[String: Any]` replies are unpacked. It wraps
/// any `HelperCalling` transport — a spawned helper, the resident helperd socket,
/// or a `serve --helper-broker` forward — because all three carry the same
/// envelope; which one it got is not this layer's business.
///
/// Before this existed, the dictionary went all the way up into the commands, so
/// every call site could misspell a key and every backend (including iOS, which
/// has no wire at all) had to speak JSONL to be callable.
final class AndroidBackend: HostBackend {
    private let transport: HelperCalling
    /// The global `--serial`, which keys the outline alias cache per device.
    private let serial: String?
    /// Where `~/.reticle/aliases` lives; a parameter only so tests can isolate it.
    private let aliasHome: URL

    init(_ transport: HelperCalling, serial: String? = nil, aliasHome: URL = OutlineAliasCache.defaultHome) {
        self.transport = transport
        self.serial = serial
        self.aliasHome = aliasHome
    }

    func close() { transport.close() }

    // MARK: - Device / runtime

    func ping() throws -> PingResult {
        let r = try transport.call(.ping)
        return PingResult(version: r["version"] as? String ?? "?")
    }

    func listDevices() throws -> [DeviceSummary] {
        devices(in: try transport.call(.listDevices))
    }

    func status(_ request: StatusRequest) throws -> StatusResult {
        let r = try transport.call(.status, ["package": request.package])
        return StatusResult(
            devices: devices(in: r),
            running: r["running"] as? Bool ?? false,
            pid: intValue(r["pid"]),
            runtime: r["runtime"] as? String,
            port: intValue(r["port"]),
            agentVersion: r["agentVersion"] as? String
        )
    }

    func launch(_ request: AppStartRequest) throws -> RuntimeStartResult {
        runtimeStart(try transport.call(.launch, startParams(request)), request)
    }

    func inject(_ request: AppStartRequest) throws -> RuntimeStartResult {
        runtimeStart(try transport.call(.inject, startParams(request)), request)
    }

    /// The payload path travels as `payloadDex`: on Android the injectable is the
    /// dexed agent jar, and the helper resolves it cwd-relative unless told
    /// otherwise (a real trap — see helper-rpc.md's "notes that bit us").
    private func startParams(_ request: AppStartRequest) -> [String: Any] {
        var params: [String: Any] = ["package": request.package]
        if let payload = request.payload { params["payloadDex"] = payload }
        if request.restartUnderDebugger { params["restartUnderDebugger"] = true }
        return params
    }

    // MARK: - Observation

    func uiReport(_ request: PackageRequest) throws -> UiReportResult {
        let r = try transport.call(.uiReport, ["package": request.package])
        var trees: [String: Any] = [:]
        for key in ["snapshot", "semantics", "compact"] {
            if let tree = r[key] { trees[key] = tree }
        }
        return UiReportResult(
            nodeCount: intValue(r["nodeCount"]),
            compactItemCount: intValue(r["compactItemCount"]),
            semanticNodeCount: intValue(r["semanticNodeCount"]),
            trees: trees
        )
    }

    func screenshot(_ request: ScreenshotRequest) throws -> ScreenshotResult {
        var params: [String: Any] = [:]
        if let package = request.package { params["package"] = package }
        let r = try transport.call(.screenshot, params)
        guard let b64 = r["pngBase64"] as? String else {
            throw HelperError("screenshot returned no image data")
        }
        return ScreenshotResult(
            pngBase64: b64,
            via: r["via"] as? String,
            degraded: (r["degraded"] as? [Any])?.map { "\($0)" } ?? []
        )
    }

    /// Every view renders HERE, from a snapshot the helper only captures — see
    /// `SnapshotRender`. `outline` also writes the `@N` alias cache `act --alias`
    /// reads, from the same window-scoped snapshot its text came from, so `@N`
    /// means what the caller just read.
    func render(_ request: RenderRequest) throws -> RenderResult {
        let snapshot = try renderSnapshot(request)
        guard request.view == "outline" else { return try SnapshotRender.render(request, snapshot: snapshot) }
        let scoped = try SnapshotRender.scoped(snapshot, window: request.window)
        let (text, entries) = Outline.render(scoped)
        if let package = request.package {
            try OutlineAliasCache.write(scoped, entries, serial: serial, package: package, home: aliasHome)
        }
        return RenderResult(text: text)
    }

    private func renderSnapshot(_ request: RenderRequest) throws -> Snapshot {
        guard request.snapshotPath == RenderRequest.liveSnapshotPath else {
            return try SnapshotRender.load(path: request.snapshotPath)
        }
        guard let package = request.package else { throw HelperError("render --live needs --package") }
        let r = try transport.call(.uiReport, ["package": package])
        guard let tree = r["snapshot"] else { throw HelperError("uiReport returned no snapshot") }
        return try SnapshotRender.decode(JSONSerialization.data(withJSONObject: tree))
    }

    func logs(_ request: PackageRequest) throws -> [AppLogEntry] {
        let r = try transport.call(.logs, ["package": request.package])
        return ((r["entries"] as? [[String: Any]]) ?? []).map {
            AppLogEntry(level: $0["level"] as? String ?? "?", message: $0["message"] as? String ?? "")
        }
    }

    func logcat() throws -> [String] {
        let r = try transport.call(.logcat)
        return (r["lines"] as? [String]) ?? []
    }

    // MARK: - Action

    func mutate(_ request: MutateRequest) throws -> MutationOutcome {
        var params: [String: Any] = [
            "package": request.package,
            "property": request.property,
            "value": request.value,
        ]
        for (key, value) in request.selector.wireParams { params[key] = value }
        let r = try transport.call(.mutate, params)
        return MutationOutcome(
            applied: r["applied"] as? Bool ?? true,
            ref: r["ref"] as? String,
            previousValue: r["previousValue"].map { "\($0)" }
        )
    }

    /// An `@N` alias is resolved against the host's outline cache here and sent as
    /// `aliasEntry`; the helper only re-finds that entry in the live tree.
    func act(_ request: ActRequest) async throws -> ActOutcome {
        if request.gesture == "wait" { return ActOutcome(raw: try await wait(request)) }
        var params = request.wireParams
        if let alias = request.selector.alias {
            let entry = try OutlineAliasCache.resolve(alias, serial: serial, package: request.package, home: aliasHome)
            params["aliasEntry"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry))
        }
        return ActOutcome(raw: try Self.judgeTap(transport.call(.act, params)))
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
        var probe = true
        let fetch: SnapshotFetch = {
            let r = try self.transport.call(.snapshot, ["package": request.package, "probe": probe])
            probe = false
            guard let tree = r["snapshot"] else { throw HelperError("snapshot returned no snapshot") }
            return try SnapshotRender.decode(JSONSerialization.data(withJSONObject: tree))
        }
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

    /// Turns a tap's `tapProbe` (the tree the helper dispatched against) into the
    /// `coverage` and `obstruction` verdicts, the way `IosGestures` judges its own
    /// taps — one `ScreenCoverage` for both platforms. The probe itself is dropped:
    /// it is a whole snapshot, and `--json` callers asked for the result.
    static func judgeTap(_ raw: [String: Any]) throws -> [String: Any] {
        guard let probe = raw["tapProbe"] as? [String: Any] else { return raw }
        var out = raw
        out.removeValue(forKey: "tapProbe")
        let x = (probe["x"] as? NSNumber)?.doubleValue ?? 0
        let y = (probe["y"] as? NSNumber)?.doubleValue ?? 0
        let rawPoint = probe["point"] as? Bool ?? false
        guard let tree = probe["snapshot"] else {
            // A tree that could not be read is reported for a coordinate (an absent
            // verdict would read as "the coordinate was fine") and stays quiet as an
            // obstruction: a check that could not run is not evidence of one.
            if rawPoint {
                let why = probe["error"] as? String ?? "the tree could not be read at dispatch time"
                out["coverage"] = ScreenCoverage.unavailable(x: x, y: y, why: why).jsonObject
            }
            return out
        }
        let snapshot = try SnapshotRender.decode(JSONSerialization.data(withJSONObject: tree))
        if rawPoint { out["coverage"] = ScreenCoverage.at(snapshot, x: x, y: y).jsonObject }
        if let obstruction = ScreenCoverage.obstruction(snapshot, x: x, y: y, targetRef: raw["ref"] as? String) {
            out["obstruction"] = obstruction.jsonObject(x: x, y: y)
        }
        backfillTrace(out)
        return out
    }

    /// The helper wrote trace.json before these verdicts existed, so they are added
    /// here, in the shape the helper used when it judged taps itself: each one a
    /// compact JSON string in the manifest's string-valued `result`. Best effort —
    /// a trace that cannot be rewritten must not fail a tap that already happened.
    static func backfillTrace(_ out: [String: Any]) {
        let verdicts = ["coverage", "obstruction"].compactMap { key in
            (out[key] as? [String: Any]).map { (key, $0) }
        }
        guard !verdicts.isEmpty, let trace = out["trace"] as? [String: Any],
              let dir = trace["path"] as? String else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent(trace["manifest"] as? String ?? "trace.json")
        guard let data = try? Data(contentsOf: url),
              var manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        var result = manifest["result"] as? [String: Any] ?? [:]
        for (key, value) in verdicts {
            guard let json = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            else { continue }
            result[key] = String(decoding: json, as: UTF8.self)
        }
        manifest["result"] = result
        guard let rewritten = try? JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        try? rewritten.write(to: url, options: .atomic)
    }

    // MARK: - Android-only device configuration

    /// Points the device's global HTTP proxy at the host, for `serve --proxy-device`.
    /// Not on `HostBackend`: iOS simulators share the host's network stack, so there
    /// is nothing to configure — an interface method every non-Android platform
    /// declined would be a worse description of reality than its absence.
    func setDeviceProxy(host: String, port: Int) throws -> (previous: String, current: String) {
        let r = try transport.call(.proxySet, ["host": host, "port": port])
        return (r["previous"] as? String ?? "", r["current"] as? String ?? "")
    }

    func setDeviceProxy(raw value: String) throws {
        _ = try transport.call(.proxySet, ["value": value])
    }

    func clearDeviceProxy(port: Int?) throws {
        var params: [String: Any] = [:]
        if let port { params["port"] = port }
        _ = try transport.call(.proxyClear, params)
    }

    /// Pushes a DER CA to the device and opens Settings for the user to confirm.
    /// Android 11+ has no silent path, which is why the result is a started intent
    /// and a message rather than "installed".
    func installDeviceCa(path: String, name: String) throws -> (started: Bool, message: String) {
        let r = try transport.call(.proxyInstallCa, ["path": path, "name": name])
        return (r["started"] as? Bool ?? false, r["message"] as? String ?? "")
    }

    // MARK: - Unpacking

    private func devices(in result: [String: Any]) -> [DeviceSummary] {
        ((result["devices"] as? [[String: Any]]) ?? []).map {
            DeviceSummary(
                serial: $0["serial"] as? String ?? "?",
                state: $0["state"] as? String ?? "?",
                name: $0["name"] as? String,
                runtime: $0["runtime"] as? String
            )
        }
    }

    private func runtimeStart(_ result: [String: Any], _ request: AppStartRequest) -> RuntimeStartResult {
        RuntimeStartResult(
            packageName: result["packageName"] as? String ?? request.package,
            pid: intValue(result["pid"]),
            port: intValue(result["port"]),
            agentVersion: result["agentVersion"] as? String,
            via: result["via"] as? String
        )
    }

    /// JSONSerialization hands integers back as `NSNumber`, and the helper's own
    /// `Int` fields arrive either way depending on the transport, so both are read.
    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int: return int
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string)
        default: return nil
        }
    }
}
