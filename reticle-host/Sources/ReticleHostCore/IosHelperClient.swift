import Foundation
import ReticleProtocol

// Disambiguate from ObjC's `Selector` (Foundation) — here we always mean the
// protocol's target selector.
private typealias TargetSelector = ReticleProtocol.Selector

/// Native in-host implementation of `HelperCalling` for iOS — no Kotlin helper,
/// no daemon broker. Device control is `xcrun simctl`; observation/mutation are
/// direct loopback HTTP to the in-process agent; screenshots use `simctl io`;
/// input synthesis uses the private CoreSimulator HID backend. Because the whole
/// CLI is written against `HelperCalling.call(method, params)`, every `cmd*`
/// function works unchanged against this client.
final class IosHelperClient: HelperCalling, @unchecked Sendable {
    private let serial: String?

    init(serial: String?) {
        self.serial = serial
    }

    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        switch method {
        case "ping":
            return ["pong": true, "version": ReticleCLI.version]
        case "listDevices":
            return try listDevices()
        case "status":
            return try status(params)
        case "launch":
            return try launchOrInject(params, inject: false)
        case "inject":
            return try launchOrInject(params, inject: true)
        case "uiReport":
            return try uiReport(params)
        case "screenshot":
            return try screenshot(params)
        case "render":
            return try render(params)
        case "mutate":
            return try mutate(params)
        case "logs":
            return try logs(params)
        case "logcat":
            // No process-wide log scrape yet on iOS; app-authored logs are /logs.
            return ["lines": [String]()]
        case "act":
            return try act(params)
        default:
            throw HelperError("iOS target (--target ios) does not support method '\(method)'")
        }
    }

    // MARK: - Devices

    private func listDevices() throws -> [String: Any] {
        let devices = try Simctl.listDevices().map { d -> [String: Any] in
            ["serial": d.udid, "state": d.state.lowercased(), "name": d.name, "runtime": d.runtime]
        }
        return ["devices": devices]
    }

    private func bundleId(_ params: [String: Any]) throws -> String {
        guard let pkg = params["package"] as? String, !pkg.isEmpty else {
            throw HelperError("iOS commands need --package <bundle-id>")
        }
        return pkg
    }

    // MARK: - Status

    private func status(_ params: [String: Any]) throws -> [String: Any] {
        let pkg = try bundleId(params)
        let devices = (try? listDevices()["devices"] as? [[String: Any]]) ?? []
        let http = IosAgentHTTP(bundleId: pkg)
        var result: [String: Any] = ["devices": devices as Any, "package": pkg]
        if let info = http.probeRuntime() {
            result["running"] = true
            result["pid"] = info.pid
            result["runtime"] = "healthy"
        } else {
            result["running"] = false
            result["runtime"] = "unreachable"
        }
        return result
    }

    // MARK: - Launch / inject

    private func launchOrInject(_ params: [String: Any], inject: Bool) throws -> [String: Any] {
        let pkg = try bundleId(params)
        let udid = try Simctl.resolveUdid(serial)
        let port = PortMap.derivePort(pkg)

        var childEnv: [String: String] = ["SIMCTL_CHILD_RETICLE_PORT": String(port)]
        if inject {
            let dylib = try resolveInjectionDylib(params)
            childEnv["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = dylib
        }
        // Restart so the injected env / a fresh runtime takes effect.
        Simctl.terminate(udid: udid, bundleId: pkg)
        let pid = try Simctl.launch(udid: udid, bundleId: pkg, childEnv: childEnv)

        // Success means the runtime is actually answering, not that launch returned.
        let http = IosAgentHTTP(bundleId: pkg)
        guard let info = http.waitForRuntime(deadline: 12.0) else {
            throw HelperError("launched \(pkg) (pid \(pid)) but its Reticle runtime never answered on port \(port); "
                + (inject ? "check the injection dylib is a simulator build and the app holds no injection block"
                          : "is ReticleKit linked and Reticle.start() called?"))
        }
        var result: [String: Any] = [
            "pid": info.pid,
            "packageName": info.packageName,
            "port": info.port,
            "agentVersion": info.agentVersion,
        ]
        if inject { result["reportedPort"] = info.port }
        return result
    }

    private func resolveInjectionDylib(_ params: [String: Any]) throws -> String {
        if let explicit = params["payloadDex"] as? String { return explicit } // reused CLI flag
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

    private func uiReport(_ params: [String: Any]) throws -> [String: Any] {
        let pkg = try bundleId(params)
        let http = IosAgentHTTP(bundleId: pkg)
        let obj = try http.getJSONObject(Endpoints.report)
        let snapshot = obj["snapshot"] as? [String: Any] ?? [:]
        let semantics = obj["semantics"] as? [String: Any] ?? [:]
        let compact = obj["compact"] as? [String: Any] ?? [:]
        let nodeCount = (snapshot["nodes"] as? [String: Any])?.count ?? 0
        let semanticCount = (semantics["nodes"] as? [String: Any])?.count ?? 0
        let compactCount = (compact["items"] as? [Any])?.count ?? 0
        return [
            "nodeCount": nodeCount,
            "compactItemCount": compactCount,
            "semanticNodeCount": semanticCount,
            "snapshot": snapshot,
            "semantics": semantics,
            "compact": compact,
        ]
    }

    private func screenshot(_ params: [String: Any]) throws -> [String: Any] {
        // The agent's in-process render always targets the app we're actually
        // talking to (device or simulator), so it is the source of truth. Only
        // fall back to `simctl io` when the agent can't render AND an explicit
        // simulator serial was given — never silently screenshot a stray booted
        // simulator when the real target is a device.
        let pkg = try bundleId(params)
        do {
            let (data, _) = try IosAgentHTTP(bundleId: pkg).get(Endpoints.screenshot)
            return ["via": "agent", "pngBase64": data.base64EncodedString()]
        } catch {
            if let serial, !serial.isEmpty,
               (try? Simctl.listDevices().contains { $0.udid == serial && $0.state == "Booted" }) == true {
                let png = try Simctl.screenshotPng(udid: serial)
                return ["via": "simctl", "pngBase64": png.base64EncodedString()]
            }
            throw error
        }
    }

    private func render(_ params: [String: Any]) throws -> [String: Any] {
        let view = (params["view"] as? String) ?? "tree"
        let snapshot = try loadSnapshotForRender(params)
        let depth = (params["depth"] as? Int) ?? Int.max
        let selector = selectorFromParams(params)
        let text = try Render.view(view, snapshot: snapshot, depth: depth, selector: selector)
        return ["text": text]
    }

    private func loadSnapshotForRender(_ params: [String: Any]) throws -> Snapshot {
        if (params["live"] as? String) == "true" {
            let pkg = try bundleId(params)
            let (data, _) = try IosAgentHTTP(bundleId: pkg).get(Endpoints.snapshot)
            return try ReticleJSON.decode(Snapshot.self, from: data)
        }
        guard let path = params["snapshot"] as? String else {
            throw HelperError("render needs a 'snapshot' path (or live=true + package)")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try ReticleJSON.decode(Snapshot.self, from: data)
    }

    private func mutate(_ params: [String: Any]) throws -> [String: Any] {
        let pkg = try bundleId(params)
        guard let property = params["property"] as? String else {
            throw HelperError("mutate needs --property")
        }
        let value = metadataValue(from: params["value"])
        let request = MutationRequest(selector: selectorFromParams(params), property: property, value: value)
        let body = try ReticleJSON.encodeWire(request)
        let (data, _) = try IosAgentHTTP(bundleId: pkg).post(Endpoints.mutate, body: body)
        let result = try ReticleJSON.decode(MutationResult.self, from: data)
        var out: [String: Any] = ["applied": result.applied]
        if let ref = result.ref { out["ref"] = ref }
        if let prev = result.previousValue { out["previousValue"] = prev.displayString() }
        if let msg = result.message { out["message"] = msg }
        return out
    }

    private func logs(_ params: [String: Any]) throws -> [String: Any] {
        let pkg = try bundleId(params)
        let obj = try IosAgentHTTP(bundleId: pkg).getJSONObject(Endpoints.logs)
        let entries = (obj["entries"] as? [[String: Any]]) ?? []
        return ["entries": entries]
    }

    // MARK: - Actions (input synthesis)

    private func act(_ params: [String: Any]) throws -> [String: Any] {
        let pkg = try bundleId(params)
        let gesture = (params["gesture"] as? String) ?? "tap"

        // Explicit in-process activation (the on-device "tap"): works everywhere,
        // no HID surface needed.
        if gesture == "activate" {
            return try activate(pkg, params)
        }

        // HID (real touch/keyboard) needs a booted simulator; a real device has no
        // host-reachable HID input surface.
        let simUdid = try? Simctl.resolveUdid(serial)

        switch gesture {
        case "tap":
            // With a selector and no simulator HID (i.e. a real device), fall back
            // to in-process activation — the device analogue of a tap.
            if simUdid == nil {
                if params["point"] != nil {
                    throw HelperError("point taps need a simulator HID surface; on a real device use `act activate` with a selector")
                }
                return try activate(pkg, params)
            }
            try assertHidAvailable(simUdid!)
            let snapshot = try fetchSnapshot(pkg)
            let screen = (snapshot.screen.size.width, snapshot.screen.size.height)
            let point = try resolveTapPoint(params, snapshot: snapshot)
            try IosInputBackend(udid: simUdid!).tap(x: point.x, y: point.y, screen: screen)
            return ["gesture": "tap", "via": "hid", "x": point.x, "y": point.y]
        case "swipe", "drag":
            guard let udid = simUdid else {
                throw HelperError("\(gesture) needs a booted simulator (real devices have no HID input surface)")
            }
            try assertHidAvailable(udid)
            guard let from = parsePoint(params["from"]), let to = parsePoint(params["to"]) else {
                throw HelperError("\(gesture) needs --from x,y and --to x,y")
            }
            let snapshot = try fetchSnapshot(pkg)
            let screen = (snapshot.screen.size.width, snapshot.screen.size.height)
            let duration = Double((params["duration"] as? String) ?? "") ?? (gesture == "drag" ? 600 : 250)
            try IosInputBackend(udid: udid).swipe(from: (from.x, from.y), to: (to.x, to.y), screen: screen, durationMs: duration)
            return ["gesture": gesture, "via": "hid", "from": "\(from.x),\(from.y)", "to": "\(to.x),\(to.y)"]
        case "type":
            guard let udid = simUdid else {
                throw HelperError("type needs a booted simulator (real devices have no HID input surface)")
            }
            try assertHidAvailable(udid)
            guard let text = params["text"] as? String else { throw HelperError("type needs --text") }
            try IosInputBackend(udid: udid).type(text)
            return ["gesture": "type", "via": "hid", "text": text]
        default:
            throw HelperError("unknown gesture '\(gesture)'")
        }
    }

    /// Fail loudly before a gesture if HID can't be brought up on this simulator.
    /// HID support is a *capability*, not a runtime-version cutoff: the recipe
    /// (SimDeviceLegacyHIDClient + a digitizer IOHIDEvent wrapped through
    /// SimulatorKit) lands touches on every runtime it can initialize on —
    /// verified on iOS 26.2 and 26.3. `isAvailable()` builds and caches the HID
    /// client (so the subsequent gesture reuses it) and returns false only when
    /// the private class/symbols are absent — e.g. an Xcode without the
    /// SimulatorKit layout this path is reverse-engineered against. In that case
    /// there is no silent no-op to fear: we error here rather than pretend.
    private func assertHidAvailable(_ udid: String) throws {
        if IosInputBackend(udid: udid).isAvailable() { return }
        throw HelperError(
            "HID input (tap/swipe/drag/type) is unavailable on this simulator: the private SimulatorKit HID "
            + "path could not be initialized (wrong/missing Xcode SimulatorKit layout). "
            + "Use `act activate` (selector or --css) instead — it drives controls in-process and needs no HID."
        )
    }

    /// In-process control activation via the agent's /activate endpoint.
    private func activate(_ pkg: String, _ params: [String: Any]) throws -> [String: Any] {
        let request = ActivationRequest(selector: selectorFromParams(params))
        let body = try ReticleJSON.encodeWire(request)
        let (data, _) = try IosAgentHTTP(bundleId: pkg).post(Endpoints.activate, body: body)
        let r = try ReticleJSON.decode(ActivationResult.self, from: data)
        if !r.activated {
            throw HelperError("activation failed: \(r.message ?? "unknown") (ref=\(r.ref ?? "?"))")
        }
        var out: [String: Any] = ["gesture": "activate", "activated": true, "via": r.via ?? "sendActions"]
        if let ref = r.ref { out["ref"] = ref }
        if let tn = r.typeName { out["typeName"] = tn }
        return out
    }

    private func fetchSnapshot(_ pkg: String) throws -> Snapshot {
        let (data, _) = try IosAgentHTTP(bundleId: pkg).get(Endpoints.snapshot)
        return try ReticleJSON.decode(Snapshot.self, from: data)
    }

    private func resolveTapPoint(_ params: [String: Any], snapshot: Snapshot) throws -> Point {
        if let p = parsePoint(params["point"]) { return p }
        let selector = selectorFromParams(params)
        guard let node = Render.findNode(snapshot, selector) else {
            throw HelperError("could not resolve a tap point from selector \(selector.describe())")
        }
        // --region narrows to a sub-target inside the node: a discovered region
        // label first (real hit-rect), else the char grid locates the substring
        // (self-drawn rows with no structural markers). Plain substring
        // matching, mirroring the Android selector resolver.
        if let query = selector.region, !query.isEmpty {
            if let region = node.regions.first(where: { ($0.label ?? "").contains(query) }),
               let p = region.tapPoint() {
                return p
            }
            if let grid = node.charGrid {
                let text = grid.text as NSString
                let r = text.range(of: query)
                if r.location != NSNotFound,
                   let rect = grid.rangeRects(start: r.location, end: r.location + r.length).first {
                    return Point(x: rect.centerX, y: rect.centerY)
                }
            }
            throw HelperError("node matched but no region or text matched '\(query)' "
                + "(\(node.regions.count) region(s), charGrid=\(node.charGrid != nil ? "yes" : "no"))")
        }
        if let f = node.frame {
            return Point(x: f.centerX, y: f.centerY)
        }
        throw HelperError("could not resolve a tap point from selector \(selector.describe())")
    }

    private func parsePoint(_ raw: Any?) -> Point? {
        guard let s = raw as? String else { return nil }
        let parts = s.split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return Point(x: x, y: y)
    }

    // MARK: - Selector / value helpers

    private func selectorFromParams(_ params: [String: Any]) -> TargetSelector {
        TargetSelector(
            testId: params["testId"] as? String,
            resourceId: params["resourceId"] as? String,
            cssSelector: params["css"] as? String,
            ref: params["ref"] as? String,
            point: parsePoint(params["point"]),
            region: params["region"] as? String
        )
    }

    /// Coerce a CLI string value into a MetadataValue (bool / int / real / text),
    /// matching how the Kotlin helper interprets `mutate --value`.
    private func metadataValue(from raw: Any?) -> MetadataValue {
        guard let s = raw as? String else {
            if let b = raw as? Bool { return .bool(b) }
            if let i = raw as? Int { return .integer(Int64(i)) }
            if let d = raw as? Double { return .real(d) }
            return .text("\(raw ?? "")")
        }
        if s == "true" || s == "false" { return .bool(s == "true") }
        if let i = Int64(s) { return .integer(i) }
        if let d = Double(s) { return .real(d) }
        return .text(s)
    }
}
