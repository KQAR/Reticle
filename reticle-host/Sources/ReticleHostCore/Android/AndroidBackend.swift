import Foundation

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
final class AndroidBackend: HostBackend, @unchecked Sendable {
    private let transport: HelperCalling

    init(_ transport: HelperCalling) {
        self.transport = transport
    }

    func close() { transport.close() }

    // MARK: - Device / runtime

    func ping() throws -> PingResult {
        let r = try transport.call("ping")
        return PingResult(version: r["version"] as? String ?? "?")
    }

    func listDevices() throws -> [DeviceSummary] {
        devices(in: try transport.call("listDevices"))
    }

    func status(_ request: StatusRequest) throws -> StatusResult {
        let r = try transport.call("status", ["package": request.package])
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
        runtimeStart(try transport.call("launch", startParams(request)), request)
    }

    func inject(_ request: AppStartRequest) throws -> RuntimeStartResult {
        runtimeStart(try transport.call("inject", startParams(request)), request)
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
        let r = try transport.call("uiReport", ["package": request.package])
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
        let r = try transport.call("screenshot", params)
        guard let b64 = r["pngBase64"] as? String else {
            throw HelperError("screenshot returned no image data")
        }
        return ScreenshotResult(
            pngBase64: b64,
            via: r["via"] as? String,
            degraded: (r["degraded"] as? [Any])?.map { "\($0)" } ?? []
        )
    }

    func render(_ request: RenderRequest) throws -> RenderResult {
        var params: [String: Any] = ["view": request.view]
        // The helper's own contract: a path, or `live: "true"` to capture now. The
        // typed request carries one field for both (a sentinel path), so the two can
        // never disagree about where the snapshot comes from; the split back into two
        // wire keys belongs here, with the rest of the wire knowledge.
        if request.snapshotPath == RenderRequest.liveSnapshotPath {
            params["live"] = "true"
        } else {
            params["snapshot"] = request.snapshotPath
        }
        if let depth = request.depth { params["depth"] = depth }
        if let package = request.package { params["package"] = package }
        for (key, value) in request.selector.wireParams { params[key] = value }
        let r = try transport.call("render", params)
        return RenderResult(text: r["text"] as? String ?? "")
    }

    func logs(_ request: PackageRequest) throws -> [AppLogEntry] {
        let r = try transport.call("logs", ["package": request.package])
        return ((r["entries"] as? [[String: Any]]) ?? []).map {
            AppLogEntry(level: $0["level"] as? String ?? "?", message: $0["message"] as? String ?? "")
        }
    }

    func logcat() throws -> [String] {
        let r = try transport.call("logcat")
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
        let r = try transport.call("mutate", params)
        return MutationOutcome(
            applied: r["applied"] as? Bool ?? true,
            ref: r["ref"] as? String,
            previousValue: r["previousValue"].map { "\($0)" }
        )
    }

    func act(_ request: ActRequest) throws -> ActOutcome {
        ActOutcome(raw: try transport.call("act", request.wireParams))
    }

    // MARK: - Android-only device configuration

    /// Points the device's global HTTP proxy at the host, for `serve --proxy-device`.
    /// Not on `HostBackend`: iOS simulators share the host's network stack, so there
    /// is nothing to configure — an interface method every non-Android platform
    /// declined would be a worse description of reality than its absence.
    func setDeviceProxy(host: String, port: Int) throws -> (previous: String, current: String) {
        let r = try transport.call("proxySet", ["host": host, "port": port])
        return (r["previous"] as? String ?? "", r["current"] as? String ?? "")
    }

    func setDeviceProxy(raw value: String) throws {
        _ = try transport.call("proxySet", ["value": value])
    }

    func clearDeviceProxy(port: Int?) throws {
        var params: [String: Any] = [:]
        if let port { params["port"] = port }
        _ = try transport.call("proxyClear", params)
    }

    /// Pushes a DER CA to the device and opens Settings for the user to confirm.
    /// Android 11+ has no silent path, which is why the result is a started intent
    /// and a message rather than "installed".
    func installDeviceCa(path: String, name: String) throws -> (started: Bool, message: String) {
        let r = try transport.call("proxyInstallCa", ["path": path, "name": name])
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
