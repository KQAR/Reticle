import Foundation
import ReticleHostShared
import ReticleProtocol

/// Native in-host `HostBackend` for iOS — no Kotlin helper, no daemon broker.
/// Device control is `xcrun simctl`/`devicectl`; observation and mutation are
/// direct loopback HTTP to the in-process agent; screenshots use the agent (with
/// `simctl io` as an explicit fallback); input synthesis uses the private
/// CoreSimulator HID backend.
///
/// It implements the typed backend interface directly. It used to implement
/// `HelperCalling` — the Android helper's *wire* shape — which meant a 30-case
/// switch over method-name strings and unpacking `[String: Any]` for parameters
/// this process had in hand all along. A backend with no wire should not have to
/// speak one to be callable.
///
/// **This file is the `HostBackend` surface and nothing else.** The type is spread
/// across the directory by concern, each half in an extension that says why it is
/// its own file — the split `IosScrollTo` and `IosVerify` started, finished:
///
/// | File | What it owns |
/// | --- | --- |
/// | `IosGestures` | `performAct`'s switch and the helpers only a gesture calls |
/// | `IosTargeting` | where an action is aimed, and the evidence that the aim held |
/// | `IosTypeText` | in-process typing, and `--clear`'s across-captures read-back |
/// | `IosWait` / `IosScrollTo` / `IosVerify` | the three gestures with their own loop |
///
/// The rule for a new member: if it does not appear in `HostBackend`, it does not
/// belong here. That is the boundary this file kept losing — it reached 1126 lines
/// and the top of the repo's churn list at the same time, which is what a type
/// looks like on the way to being untouchable.
public final class IosHelperClient: HostBackend {
    let serial: String?

    public init(serial: String?) {
        self.serial = serial
    }

    public func ping() throws -> PingResult {
        PingResult(version: ReticleVersion.current)
    }

    public func listDevices() async throws -> [DeviceSummary] {
        await try Simctl.listDevices().map {
            DeviceSummary(serial: $0.udid, state: $0.state.lowercased(), name: $0.name, runtime: $0.runtime)
        }
    }

    public func status(_ request: StatusRequest) async throws -> StatusResult {
        // Runtime health comes over loopback and doesn't need simctl, so a simctl
        // failure shouldn't fail the whole status — but it must be reported, not
        // swallowed into an empty device list that reads like "no simulators".
        var devices: [DeviceSummary] = []
        do {
            devices = await try listDevices()
        } catch {
            FileHandle.standardError.write(Data("warning: could not list simulators: \(error)\n".utf8))
        }
        if let info = await IosAgentHTTP(bundleId: request.package).probeRuntime() {
            return StatusResult(devices: devices, running: true, pid: info.pid, runtime: "healthy",
                                port: info.port, agentVersion: info.agentVersion)
        }
        return StatusResult(devices: devices, running: false, pid: nil, runtime: "unreachable")
    }

    public func launch(_ request: AppStartRequest) async throws -> RuntimeStartResult {
        try await start(request, inject: false)
    }

    public func inject(_ request: AppStartRequest) async throws -> RuntimeStartResult {
        // `--restart-under-debugger` relaxes Android's input-dispatch ANR during a
        // JDWP suspension. iOS injection is a DYLD insert with no suspended main
        // thread and no AMS, so there is nothing here for the flag to do. Refuse it
        // by name rather than accepting it and doing nothing.
        if request.restartUnderDebugger {
            throw HelperError("--restart-under-debugger is Android-only: it relaxes the ANR that "
                + "Android's JDWP suspension can trip. iOS injection is a DYLD insert and suspends nothing.")
        }
        return try await start(request, inject: true)
    }

    public func logcat() throws -> [String] {
        // No process-wide log scrape yet on iOS; app-authored logs are `logs`.
        []
    }

    // MARK: - Devices

    func bundleId(_ params: [String: Any]) throws -> String {
        guard let pkg = params["package"] as? String, !pkg.isEmpty else {
            throw HelperError("iOS commands need --package <bundle-id>")
        }
        return pkg
    }

    // MARK: - Launch / inject

    private func start(_ request: AppStartRequest, inject: Bool) async throws -> RuntimeStartResult {
        let pkg = request.package
        let udid = await try Simctl.resolveUdid(serial)
        let port = PortMap.derivePort(pkg)

        var childEnv: [String: String] = ["SIMCTL_CHILD_RETICLE_PORT": String(port)]
        if inject {
            childEnv["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = try resolveInjectionDylib(request.payload)
        }
        // Restart so the injected env / a fresh runtime takes effect.
        await Simctl.terminate(udid: udid, bundleId: pkg)
        let pid = await try Simctl.launch(udid: udid, bundleId: pkg, childEnv: childEnv)

        // Success means the runtime is actually answering, not that launch returned.
        guard let info = await IosAgentHTTP(bundleId: pkg).waitForRuntime(deadline: 12.0) else {
            throw HelperError("launched \(pkg) (pid \(pid)) but its Reticle runtime never answered on port \(port); "
                + (inject ? "check the injection dylib is a simulator build and the app holds no injection block"
                          : "is ReticleKit linked and Reticle.start() called?"))
        }
        return RuntimeStartResult(packageName: info.packageName, pid: info.pid, port: info.port,
                                  agentVersion: info.agentVersion)
    }

    private func resolveInjectionDylib(_ payload: String?) throws -> String {
        if let payload { return payload }
        if let env = ProcessInfo.processInfo.environment["RETICLE_IOS_INJECTION"] { return env }
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        // SwiftPM names the output dir after the host triple even when cross-
        // compiling for the simulator, so the dylib commonly lands under
        // arm64-apple-macosx/. Check the known spots.
        let candidates = [
            "reticle-agent/ios/.build/arm64-apple-macosx/debug/libReticleInjection.dylib",
            "reticle-agent/ios/.build/arm64-apple-ios-simulator/debug/libReticleInjection.dylib",
            "reticle-agent/ios/.build/debug/libReticleInjection.dylib",
        ].map { cwd + "/" + $0 }
        for c in candidates where fm.fileExists(atPath: c) { return c }
        throw HelperError("could not locate libReticleInjection.dylib; build it (scripts/build-ios-agent.sh) "
            + "or set RETICLE_IOS_INJECTION to its path")
    }

    // MARK: - Observation

    public func uiReport(_ request: PackageRequest) async throws -> UiReportResult {
        let obj = try await IosAgentHTTP(bundleId: request.package).getJSONObject(Endpoints.report)
        let snapshot = obj["snapshot"] as? [String: Any] ?? [:]
        let semantics = obj["semantics"] as? [String: Any] ?? [:]
        let compact = obj["compact"] as? [String: Any] ?? [:]
        return UiReportResult(
            nodeCount: (snapshot["nodes"] as? [String: Any])?.count ?? 0,
            compactItemCount: (compact["items"] as? [Any])?.count ?? 0,
            semanticNodeCount: (semantics["nodes"] as? [String: Any])?.count ?? 0,
            trees: ["snapshot": snapshot, "semantics": semantics, "compact": compact]
        )
    }

    public func screenshot(_ request: ScreenshotRequest) async throws -> ScreenshotResult {
        // The agent's in-process render always targets the app we're actually
        // talking to (device or simulator), so it is the source of truth. Only
        // fall back to `simctl io` when the agent can't render AND an explicit
        // simulator serial was given — never silently screenshot a stray booted
        // simulator when the real target is a device.
        guard let pkg = request.package, !pkg.isEmpty else {
            throw HelperError("iOS commands need --package <bundle-id>")
        }
        do {
            let (data, _) = try await IosAgentHTTP(bundleId: pkg).get(Endpoints.screenshot)
            return ScreenshotResult(pngBase64: data.base64EncodedString(), via: "agent",
                                    degraded: await screenshotDegrades(pkg))
        } catch {
            if let serial, !serial.isEmpty,
               await (try? Simctl.listDevices().contains { $0.udid == serial && $0.state == "Booted" }) == true {
                let png = await try Simctl.screenshotPng(udid: serial)
                return ScreenshotResult(pngBase64: png.base64EncodedString(), via: "simctl")
            }
            throw error
        }
    }

    /// What the in-process picture is missing, said out loud rather than left as a
    /// blank rect: nodes the agent marked `pixels:unavailable` — on iOS the system
    /// keyboard's host window, which refuses to render into a borrowed context, so
    /// the keys are simply absent from the image (measured against
    /// `simctl io screenshot`). Best-effort: no snapshot, no note.
    private func screenshotDegrades(_ pkg: String) async -> [String] {
        guard let snapshot = try? await fetchSnapshot(pkg) else { return [] }
        return snapshot.nodes.values.filter { $0.pixelsUnavailable() }.map { node in
            let id = node.testId ?? node.ref
            let where_ = node.frame.map { " [\($0.intDescription)]" } ?? ""
            // `typeName` is non-optional, so the old `?? "this window"` never fired;
            // an unnamed node still needs the fallback, which is the empty check.
            let kind = node.typeName.isEmpty ? "this window" : node.typeName
            return "\(id)\(where_) is not in this picture: \(kind) "
                + "does not render into an in-process context. A device-level capture "
                + "(`xcrun simctl io <udid> screenshot`) shows it."
        }
    }

    /// `--alias` is Android-only: the `@N` numbers are handed out by `ui outline`, which
    /// is the Kotlin helper's own host-side cache (`OutlineRenderer`). This host keeps no
    /// such cache, so an alias here can resolve to nothing.
    ///
    /// It is refused BY NAME at every iOS entry point that takes a selector, rather than
    /// narrowed away in `HostSelector.protocolSelector` — where it used to vanish
    /// silently, leaving the command to run with NO selector at all. That is the failure
    /// this repo has already paid for once (see the `act tap --text` note in
    /// `ReticleCLI`): a flag accepted and ignored reads as a flag that worked.
    static func rejectAlias(_ alias: String?, command: String) throws {
        guard alias != nil else { return }
        throw HelperError(
            "\(command) cannot take --alias on iOS: `@N` aliases are handed out by "
                + "`ui outline`, which is Android-only (the alias cache lives in the Kotlin "
                + "helper). Use --test-id / --resource-id / --css / --ref / --label — "
                + "`ui compact` prints one for every item on the screen."
        )
    }

    public func render(_ request: RenderRequest) async throws -> RenderResult {
        try Self.rejectAlias(request.selector.alias, command: "ui \(request.view)")
        var snapshot = try await loadSnapshotForRender(request)
        if let window = request.window {
            guard let scoped = snapshot.scopedToWindow(window) else {
                let refs = snapshot.windowRefs()
                throw HelperError("no window '\(window)' in this capture. Windows here (bottom to top): "
                    + (refs.isEmpty ? "(none — this capture has no window nodes)" : refs.joined(separator: ", "))
                    + ". Use `--window top` for whichever is on top.")
            }
            snapshot = scoped
        }
        let text = try Render.view(
            request.view,
            snapshot: snapshot,
            depth: request.depth ?? Int.max,
            selector: request.selector.protocolSelector
        )
        return RenderResult(text: text)
    }

    private func loadSnapshotForRender(_ request: RenderRequest) async throws -> Snapshot {
        // `--live` arrives as the sentinel path the CLI uses for "capture now".
        if request.snapshotPath == RenderRequest.liveSnapshotPath {
            guard let pkg = request.package else {
                throw HelperError("render --live needs --package")
            }
            let (data, _) = try await IosAgentHTTP(bundleId: pkg).get(Endpoints.snapshot)
            return try ReticleJSON.decode(Snapshot.self, from: data).requireSupportedSchema()
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: request.snapshotPath))
        return try ReticleJSON.decode(Snapshot.self, from: data).requireSupportedSchema()
    }

    public func mutate(_ request: MutateRequest) async throws -> MutationOutcome {
        try Self.rejectAlias(request.selector.alias, command: "mutate")
        let mutation = MutationRequest(
            selector: request.selector.protocolSelector,
            property: request.property,
            value: MetadataValue.parsed(from: request.value)
        )
        let body = try ReticleJSON.encodeWire(mutation)
        let (data, _) = try await IosAgentHTTP(bundleId: request.package).post(Endpoints.mutate, body: body)
        let result = try ReticleJSON.decode(MutationResult.self, from: data)
        return MutationOutcome(
            applied: result.applied,
            ref: result.ref,
            previousValue: result.previousValue?.displayString()
        )
    }

    public func logs(_ request: PackageRequest) async throws -> [AppLogEntry] {
        let obj = try await IosAgentHTTP(bundleId: request.package).getJSONObject(Endpoints.logs)
        return ((obj["entries"] as? [[String: Any]]) ?? []).map {
            AppLogEntry(level: $0["level"] as? String ?? "?", message: $0["message"] as? String ?? "")
        }
    }
}
