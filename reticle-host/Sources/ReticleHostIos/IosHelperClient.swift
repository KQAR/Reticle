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
public final class IosHelperClient: HostBackend, @unchecked Sendable {
    let serial: String?

    public init(serial: String?) {
        self.serial = serial
    }

    public func ping() throws -> PingResult {
        PingResult(version: ReticleVersion.current)
    }

    public func listDevices() throws -> [DeviceSummary] {
        try Simctl.listDevices().map {
            DeviceSummary(serial: $0.udid, state: $0.state.lowercased(), name: $0.name, runtime: $0.runtime)
        }
    }

    public func status(_ request: StatusRequest) throws -> StatusResult {
        // Runtime health comes over loopback and doesn't need simctl, so a simctl
        // failure shouldn't fail the whole status — but it must be reported, not
        // swallowed into an empty device list that reads like "no simulators".
        var devices: [DeviceSummary] = []
        do {
            devices = try listDevices()
        } catch {
            FileHandle.standardError.write(Data("warning: could not list simulators: \(error)\n".utf8))
        }
        if let info = IosAgentHTTP(bundleId: request.package).probeRuntime() {
            return StatusResult(devices: devices, running: true, pid: info.pid, runtime: "healthy",
                                port: info.port, agentVersion: info.agentVersion)
        }
        return StatusResult(devices: devices, running: false, pid: nil, runtime: "unreachable")
    }

    public func launch(_ request: AppStartRequest) throws -> RuntimeStartResult {
        try start(request, inject: false)
    }

    public func inject(_ request: AppStartRequest) throws -> RuntimeStartResult {
        // `--restart-under-debugger` relaxes Android's input-dispatch ANR during a
        // JDWP suspension. iOS injection is a DYLD insert with no suspended main
        // thread and no AMS, so there is nothing here for the flag to do. Refuse it
        // by name rather than accepting it and doing nothing.
        if request.restartUnderDebugger {
            throw HelperError("--restart-under-debugger is Android-only: it relaxes the ANR that "
                + "Android's JDWP suspension can trip. iOS injection is a DYLD insert and suspends nothing.")
        }
        return try start(request, inject: true)
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

    private func start(_ request: AppStartRequest, inject: Bool) throws -> RuntimeStartResult {
        let pkg = request.package
        let udid = try Simctl.resolveUdid(serial)
        let port = PortMap.derivePort(pkg)

        var childEnv: [String: String] = ["SIMCTL_CHILD_RETICLE_PORT": String(port)]
        if inject {
            childEnv["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = try resolveInjectionDylib(request.payload)
        }
        // Restart so the injected env / a fresh runtime takes effect.
        Simctl.terminate(udid: udid, bundleId: pkg)
        let pid = try Simctl.launch(udid: udid, bundleId: pkg, childEnv: childEnv)

        // Success means the runtime is actually answering, not that launch returned.
        guard let info = IosAgentHTTP(bundleId: pkg).waitForRuntime(deadline: 12.0) else {
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

    public func uiReport(_ request: PackageRequest) throws -> UiReportResult {
        let obj = try IosAgentHTTP(bundleId: request.package).getJSONObject(Endpoints.report)
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

    public func screenshot(_ request: ScreenshotRequest) throws -> ScreenshotResult {
        // The agent's in-process render always targets the app we're actually
        // talking to (device or simulator), so it is the source of truth. Only
        // fall back to `simctl io` when the agent can't render AND an explicit
        // simulator serial was given — never silently screenshot a stray booted
        // simulator when the real target is a device.
        guard let pkg = request.package, !pkg.isEmpty else {
            throw HelperError("iOS commands need --package <bundle-id>")
        }
        do {
            let (data, _) = try IosAgentHTTP(bundleId: pkg).get(Endpoints.screenshot)
            return ScreenshotResult(pngBase64: data.base64EncodedString(), via: "agent",
                                    degraded: screenshotDegrades(pkg))
        } catch {
            if let serial, !serial.isEmpty,
               (try? Simctl.listDevices().contains { $0.udid == serial && $0.state == "Booted" }) == true {
                let png = try Simctl.screenshotPng(udid: serial)
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
    private func screenshotDegrades(_ pkg: String) -> [String] {
        guard let snapshot = try? fetchSnapshot(pkg) else { return [] }
        return snapshot.nodes.values.filter { $0.pixelsUnavailable() }.map { node in
            let id = node.testId ?? node.ref
            let where_ = node.frame.map { " [\($0.intDescription)]" } ?? ""
            return "\(id)\(where_) is not in this picture: \(node.typeName ?? "this window") "
                + "does not render into an in-process context. A device-level capture "
                + "(`xcrun simctl io <udid> screenshot`) shows it."
        }
    }

    public func render(_ request: RenderRequest) throws -> RenderResult {
        var snapshot = try loadSnapshotForRender(request)
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

    private func loadSnapshotForRender(_ request: RenderRequest) throws -> Snapshot {
        // `--live` arrives as the sentinel path the CLI uses for "capture now".
        if request.snapshotPath == RenderRequest.liveSnapshotPath {
            guard let pkg = request.package else {
                throw HelperError("render --live needs --package")
            }
            let (data, _) = try IosAgentHTTP(bundleId: pkg).get(Endpoints.snapshot)
            return try ReticleJSON.decode(Snapshot.self, from: data).requireSupportedSchema()
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: request.snapshotPath))
        return try ReticleJSON.decode(Snapshot.self, from: data).requireSupportedSchema()
    }

    public func mutate(_ request: MutateRequest) throws -> MutationOutcome {
        let mutation = MutationRequest(
            selector: request.selector.protocolSelector,
            property: request.property,
            value: MetadataValue.parsed(from: request.value)
        )
        let body = try ReticleJSON.encodeWire(mutation)
        let (data, _) = try IosAgentHTTP(bundleId: request.package).post(Endpoints.mutate, body: body)
        let result = try ReticleJSON.decode(MutationResult.self, from: data)
        return MutationOutcome(
            applied: result.applied,
            ref: result.ref,
            previousValue: result.previousValue?.displayString()
        )
    }

    public func logs(_ request: PackageRequest) throws -> [AppLogEntry] {
        let obj = try IosAgentHTTP(bundleId: request.package).getJSONObject(Endpoints.logs)
        return ((obj["entries"] as? [[String: Any]]) ?? []).map {
            AppLogEntry(level: $0["level"] as? String ?? "?", message: $0["message"] as? String ?? "")
        }
    }

    // MARK: - Actions (input synthesis)

    /// Runs one gesture, wrapping it in `--verify` before/after node-state diffing
    /// when requested — the iOS analogue of the Android helper's `HelperVerify`,
    /// producing the same `verify` result shape the host's `printVerify` renders.
    /// Previously iOS silently accepted and dropped `--verify`, so an agent believed
    /// it had checked a post-condition it never checked.
    public func act(_ request: ActRequest) throws -> ActOutcome {
        ActOutcome(raw: try act(request.wireParams))
    }

    /// The gesture handler still reads a parameter dictionary, and `act` is the one
    /// method where that is not just inertia: `act batch` builds steps from user
    /// JSON, and the modifiers are shared across gestures. The typed entry point
    /// above is what callers see; converting this body is tracked separately so the
    /// interface change and the internal one are reviewable apart.
    private func act(_ params: [String: Any]) throws -> [String: Any] {
        guard let watch = try verifyWatchSelector(params) else {
            return try performAct(params)
        }
        let pkg = try bundleId(params)
        let before = captureVerifyState(pkg, watch)
        var result = try performAct(params)
        result["verify"] = pollVerify(pkg, watch, before: before, params: params)
        return result
    }

    func performAct(_ params: [String: Any]) throws -> [String: Any] {
        let pkg = try bundleId(params)
        let gesture = (params["gesture"] as? String) ?? "tap"

        // When `--trace-output` (or an active session) is set, wrap the action in a
        // before/after evidence package — the same trace shape Android emits, so
        // `reticle serve` and the panel ingest an iOS action identically.
        let tracer = (params["traceOutput"] as? String).map {
            IosActionTrace(
                root: URL(fileURLWithPath: $0),
                packageName: pkg,
                http: IosAgentHTTP(bundleId: pkg),
                // Captured here, from the request, for the same reason the Kotlin
                // helper captures at construction: by the time the trace is written
                // the request has been reduced to a result, and a `type`'s text is
                // no longer recoverable from it.
                recordedParams: ActionTraceParamNames.capture(from: params)
            )
        }
        let settleMs = (params["traceDelayMs"] as? Int) ?? 250
        let selector = selectorForTrace(params)

        // Explicit in-process activation (the on-device "tap"): works everywhere,
        // no HID surface needed.
        if gesture == "activate" {
            let before = tracer?.capture()
            let result = try activate(pkg, params)
            return try finishTrace(tracer, before, settleMs, gesture: "activate", selector: selector,
                                   point: nil, source: result["via"] as? String, ref: result["ref"] as? String,
                                   result: result)
        }

        // In-process keyboard dismissal: no HID surface needed, so it works on
        // devices and simulators alike, and reports the settled before/after
        // state straight from the agent.
        if gesture == "hideKeyboard" || gesture == "hide-keyboard" {
            let before = tracer?.capture()
            let obj: [String: Any]
            do {
                let (data, _) = try IosAgentHTTP(bundleId: pkg).post(Endpoints.keyboardHide, body: Data())
                obj = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            } catch {
                throw HelperError("hide-keyboard needs the in-process agent (is the runtime up?): \(error)")
            }
            let keyboard = obj["keyboard"] as? [String: Any]
            return try finishTrace(tracer, before, settleMs, gesture: "hideKeyboard", selector: nil,
                                   point: nil, source: "agent", ref: nil,
                                   result: ["gesture": "hideKeyboard", "via": "agent resignFirstResponder",
                                            "wasVisible": obj["wasVisible"] ?? false,
                                            "keyboardVisible": keyboard?["visible"] ?? false])
        }

        // The one gesture that dispatches no input: it only observes, so like
        // `hide-keyboard` it needs no HID surface and works on real devices too.
        if gesture == "wait" {
            let predicate = try IosWaitRunner.predicate(from: params)
            let runner = IosWaitRunner(fetch: { try self.fetchSnapshot(pkg) })
            return try runner.run(
                predicate: predicate,
                timeoutMs: (params["timeoutMs"] as? Int) ?? WaitSchedule.defaultTimeoutMs,
                quietMs: (params["quietMs"] as? Int) ?? WaitSchedule.defaultQuietMs
            )
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
                let before = tracer?.capture()
                var result = try activate(pkg, params)
                // `--settle` is about a coordinate going stale between resolve and
                // dispatch; in-process activation does both in one step, so there is
                // nothing to wait out. Say so rather than reporting a settle that
                // never ran.
                if settleRequested(params) {
                    result["settleSkipped"] = "activation resolves and dispatches in-process"
                }
                return try finishTrace(tracer, before, settleMs, gesture: "tap", selector: selector,
                                       point: nil, source: result["via"] as? String, ref: result["ref"] as? String,
                                       result: result)
            }
            try assertHidAvailable(simUdid!)
            let snapshot = try fetchSnapshot(pkg)
            let screen = (snapshot.screen.size.width, snapshot.screen.size.height)
            let target = try resolveTarget(params, snapshot: snapshot)
            let firstPoint = target.point
            var point = firstPoint
            var stable: Bool? = nil
            let rawPoint = params["point"] != nil
            if settleRequested(params), rawPoint {
                throw HelperError("--settle needs a selector: a raw --point has nothing to re-resolve, "
                    + "so there is no way to tell whether it has stopped moving")
            }
            // Confirm the point before dispatching, by DEFAULT for a selector tap —
            // the Android helper's twin, and for the same measured reason: a rect
            // resolved before an intervening relayout (a keyboard shown by an earlier
            // `type`, a scroll) sends the touch to the neighbouring control while the
            // command reports an unqualified success. `--settle` raises the budget for
            // a target that is genuinely animating in; `--no-settle` opts out.
            if !rawPoint, !isTruthy(params["noSettle"]) {
                let settled = settleTapPoint(pkg, params, first: point)
                point = settled.point
                stable = settled.stable
            }
            // Judged BEFORE the touch, off the snapshot this tap already resolved
            // against: was a selector available at this coordinate, or did a named
            // boundary make pixels the only path? The Android helper's twin — see
            // `HelperPointCoverage.kt` for why a silent `--point` is the defect.
            let coverage = rawPoint ? ScreenCoverage.at(snapshot, x: point.x, y: point.y) : nil
            // And who would receive the touch instead of the target, which a
            // SELECTOR tap needs too: it resolves correctly, confirms the rect, and
            // is then eaten by the IME or by a window above the one it aimed at.
            let obstruction = ScreenCoverage.obstruction(snapshot, x: point.x, y: point.y, targetRef: target.ref)
            let before = tracer?.capture()
            try IosInputBackend(udid: simUdid!).tap(x: point.x, y: point.y, screen: screen)
            var result: [String: Any] = [
                "gesture": "tap", "via": "hid", "x": point.x, "y": point.y,
                // How it resolved, in the shared vocabulary (`semantic:testId`,
                // `region:span`, `charGrid:approx`, …). It used to report the
                // coarse "selector", which threw away exactly the distinction an
                // agent needs: a char-grid approximation is not a semantic hit.
                "source": target.source,
            ]
            if let ref = target.ref { result["ref"] = ref }
            // Only part of the frame was reachable, so the tap aimed at the visible
            // part rather than at a centre that is no longer inside it.
            if let reachNote = target.reachNote { result["reach"] = reachNote }
            if let coverage { result["coverage"] = coverage.jsonObject }
            if let obstruction { result["obstruction"] = obstruction.jsonObject(x: point.x, y: point.y) }
            // Honest flag, as in scroll-to: false means the target was still moving
            // when the budget lapsed, so this tap may have been aimed at a point that
            // had already changed.
            if let stable { result["settled"] = stable }
            // The evidence that the first read WAS stale: same selector, same ref,
            // different coordinates. Without it the confirm silently fixes the tap
            // and the caller never learns the screen moved under it.
            let dx = Int(point.x - firstPoint.x), dy = Int(point.y - firstPoint.y)
            if dx != 0 || dy != 0 { result["rectMoved"] = "\(dx),\(dy)" }
            return try finishTrace(tracer, before, settleMs, gesture: "tap", selector: selector,
                                   point: point, source: target.source, ref: target.ref,
                                   result: result)
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
            let before = tracer?.capture()
            try IosInputBackend(udid: udid).swipe(from: (from.x, from.y), to: (to.x, to.y), screen: screen, durationMs: duration)
            return try finishTrace(tracer, before, settleMs, gesture: gesture, selector: selector,
                                   point: from, source: "point", ref: nil,
                                   result: ["gesture": gesture, "via": "hid", "from": "\(from.x),\(from.y)", "to": "\(to.x),\(to.y)"])
        case "scroll-to", "scrollTo":
            guard let udid = simUdid else {
                throw HelperError("scroll-to needs a booted simulator (real devices have no HID input surface)")
            }
            try assertHidAvailable(udid)
            return try scrollTo(pkg, params, udid: udid)
        case "type":
            guard let udid = simUdid else {
                throw HelperError("type needs a booted simulator (real devices have no HID input surface)")
            }
            try assertHidAvailable(udid)
            guard let text = params["text"] as? String else { throw HelperError("type needs --text") }
            let before = tracer?.capture()
            // If the caller named a target field, tap it first so the text lands
            // in THAT field — HID typing and clipboard paste both go to whatever
            // currently holds focus, so `type --test-id foo` otherwise silently
            // typed into the wrong (or no) field. Mirrors the Android helper's
            // focus-tap; with no target, type into the current focus.
            var focusedVia: String? = nil
            var focusPoint: Point? = nil
            if selector != nil {
                let snapshot = try fetchSnapshot(pkg)
                let screen = (snapshot.screen.size.width, snapshot.screen.size.height)
                let point = try resolveTapPoint(params, snapshot: snapshot)
                try IosInputBackend(udid: udid).tap(x: point.x, y: point.y, screen: screen)
                focusPoint = point
                // Give the tapped field a beat to take focus before dispatching
                // text (the Android helper settles 200ms for the same reason).
                Thread.sleep(forTimeInterval: 0.2)
                focusedVia = params["point"] != nil ? "point" : "selector"
            }
            // `--clear`: empty the field BEFORE typing, and prove it is empty.
            // Android's twin (`clearField` in HelperDeviceCommands.kt) and the same
            // measured defect: the flag was accepted and did nothing, so a field
            // that already held "test1" ended up holding "test1test1" while the
            // result read like a clean write.
            var cleared: [String: Any]? = nil
            var clearedSummary: String? = nil
            if isTruthy(params["clear"]) {
                let outcome = try clearFocusedField(pkg, udid: udid, params: params)
                cleared = outcome.wire
                clearedSummary = outcome.summary
                if !outcome.emptied {
                    throw HelperError(
                        "--clear did not empty the field (\(outcome.describe())), so typing now would "
                        + "APPEND to what is still there and report success — refusing. Clear it by hand "
                        + "or drop --clear if appending is what you meant"
                    )
                }
            }
            let via: String
            if IosText.isHidTypeable(text) {
                try IosInputBackend(udid: udid).type(text)
                via = "hid"
            } else {
                // The HID keyboard can't emit non-ASCII (CJK / emoji / accented).
                // Stage it on the clipboard via the in-process agent, then Cmd+V —
                // the iOS analogue of Android's clipboard + KEYCODE_PASTE path.
                // Pastes into the current focus — the focus-tap above (or the
                // caller) must have put the caret in the right field.
                do {
                    try IosAgentHTTP(bundleId: pkg).post(Endpoints.clipboard, body: Data(text.utf8))
                } catch {
                    throw HelperError("could not stage non-ASCII text on the clipboard (is the agent running?): \(error)")
                }
                // The agent sets UIPasteboard on the main thread asynchronously;
                // give it a beat to land before pasting.
                Thread.sleep(forTimeInterval: 0.12)
                try IosInputBackend(udid: udid).paste()
                via = "clipboard paste"
            }
            var result: [String: Any] = ["gesture": "type", "via": via, "text": text]
            if let clearedSummary { result["cleared"] = clearedSummary }
            if let cleared { result["clearDetail"] = cleared }
            if let focusedVia { result["focusedVia"] = focusedVia }
            // `type --submit`: press Return after the text lands. The HID
            // bridge maps '\n' to the Return usage, which triggers the focused
            // field's return-key action (textFieldShouldReturn / onSubmitEditing).
            if isTruthy(params["submit"]) {
                Thread.sleep(forTimeInterval: 0.15)
                try IosInputBackend(udid: udid).type("\n")
                result["submit"] = ["via": "hid return"]
            }
            // Opportunistic post-type keyboard state (typing almost always
            // leaves the keyboard covering the bottom of the screen); omitted
            // when the agent can't answer — typing must not fail over it.
            if let visible = (try? IosAgentHTTP(bundleId: pkg).getJSONObject(Endpoints.keyboard))?["visible"] as? Bool {
                result["keyboardVisible"] = visible
            }
            return try finishTrace(tracer, before, settleMs, gesture: "type", selector: selector,
                                   point: focusPoint, source: focusedVia, ref: nil,
                                   result: result)
        default:
            throw HelperError("unknown gesture '\(gesture)'")
        }
    }

    /// Merge a trace evidence package into an action result when tracing is on and
    /// the before-state was captured; otherwise return the result untouched.
    func finishTrace(
        _ tracer: IosActionTrace?, _ before: IosActionTrace.Capture?, _ settleMs: Int,
        gesture: String, selector: TargetSelector?,
        point: Point?, source: String?, ref: String?,
        result: [String: Any]
    ) throws -> [String: Any] {
        guard let tracer, let before else { return result }
        var out = result
        out["trace"] = try tracer.write(
            gesture: gesture, selector: selector, targetPoint: point, targetSource: source, targetRef: ref,
            result: result.mapValues { "\($0)" }, before: before, settleMs: settleMs
        )
        return out
    }

    /// The selector to record in a trace, or nil when no selector fields were
    /// given (a bare point/coordinate action). Mirrors the helper's `selectorOrNull`.
    func selectorForTrace(_ params: [String: Any]) -> TargetSelector? {
        let s = selectorFromParams(params)
        let empty = s.testId == nil && s.resourceId == nil && s.cssSelector == nil
            && s.ref == nil && s.point == nil && s.region == nil
        return empty ? nil : s
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
    func assertHidAvailable(_ udid: String) throws {
        if IosInputBackend(udid: udid).isAvailable() { return }
        throw HelperError(
            "HID input (tap/swipe/drag/type) is unavailable on this simulator: the private SimulatorKit HID "
            + "path could not be initialized (wrong/missing Xcode SimulatorKit layout). "
            + "Use `act activate` (selector or --css) instead — it drives controls in-process and needs no HID."
        )
    }

    /// In-process control activation via the agent's /activate endpoint.
    func activate(_ pkg: String, _ params: [String: Any]) throws -> [String: Any] {
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

    /// What `--clear` did on the iOS side, and whether the field is provably empty.
    struct ClearOutcome {
        var emptied: Bool
        var before: String?
        var after: String?
        var deletes: Int
        var unavailable: String?

        func describe() -> String {
            if let unavailable { return "the field could not be read back: \(unavailable)" }
            guard let after else { return "the field could not be read back" }
            return "it still holds \(after.count) char(s)"
        }

        /// One field, one token — see the Kotlin twin.
        var summary: String {
            if emptied && deletes == 0 { return "already-empty" }
            if emptied { return "emptied(\(deletes)ch)" }
            if let unavailable { return "failed:\(unavailable)" }
            return "failed:\(after?.count ?? 0)ch-left"
        }

        var wire: [String: Any] {
            var out: [String: Any] = ["emptied": emptied, "deletes": deletes]
            if let before { out["before"] = before }
            if let after { out["after"] = after }
            if let unavailable { out["unavailable"] = unavailable }
            return out
        }
    }

    /// The focused text field's current value, from the tree.
    private static func editableText(_ node: Node) -> String? {
        if case .text(let value)? = node.custom["editableText"] { return value }
        return node.text
    }

    /// The field the caller is typing into: the focused one, or the resolved target.
    private func focusedField(_ snapshot: Snapshot, params: [String: Any]) -> Node? {
        if let focused = snapshot.nodes.values.first(where: { $0.isFocused == true && $0.role == "textField" }) {
            return focused
        }
        guard let resolved = try? resolveTarget(params, snapshot: snapshot), let ref = resolved.ref else {
            return nil
        }
        return snapshot.nodes[ref]
    }

    /// Empty the focused field with one Delete per character it actually holds,
    /// then read it back. Deleting what is there rather than a fixed count is the
    /// difference between clearing the field and eating the line above it; the
    /// read-back is what stops `--clear` claiming work it did not do.
    func clearFocusedField(_ pkg: String, udid: String, params: [String: Any]) throws -> ClearOutcome {
        let snapshot = try fetchSnapshot(pkg)
        guard let field = focusedField(snapshot, params: params) else {
            return ClearOutcome(emptied: false, before: nil, after: nil, deletes: 0,
                                unavailable: "no-text-field-node")
        }
        guard let before = Self.editableText(field) else {
            return ClearOutcome(emptied: false, before: nil, after: nil, deletes: 0,
                                unavailable: "field-exposes-no-text")
        }
        if before.isEmpty {
            return ClearOutcome(emptied: true, before: before, after: before, deletes: 0, unavailable: nil)
        }
        if before.count > Self.maxClearDeletes {
            return ClearOutcome(
                emptied: false, before: before, after: before, deletes: 0,
                unavailable: "field-too-long (\(before.count) chars, limit \(Self.maxClearDeletes))"
            )
        }
        try IosInputBackend(udid: udid).delete(times: before.count)
        Thread.sleep(forTimeInterval: 0.25)
        let after = (try? fetchSnapshot(pkg))
            .flatMap { $0.nodes[field.ref] }
            .flatMap { Self.editableText($0) }
        return ClearOutcome(
            emptied: after?.isEmpty == true, before: before, after: after,
            deletes: before.count, unavailable: after == nil ? "node-gone" : nil
        )
    }

    /// A field longer than this is not hammered with hundreds of key events — it is
    /// reported as not cleared and the caller decides. Matches the Android limit.
    static let maxClearDeletes = 64

    func fetchSnapshot(_ pkg: String) throws -> Snapshot {
        let (data, _) = try IosAgentHTTP(bundleId: pkg).get(Endpoints.snapshot)
        return try ReticleJSON.decode(Snapshot.self, from: data).requireSupportedSchema()
    }

    /// Resolves a tap target through the SHARED resolver in `ReticleProtocol`, the
    /// same order the Kotlin helper applies and the same one pinned by
    /// `reticle-protocol/fixtures/selector-resolution.cases.json`.
    ///
    /// This used to be a hand-rolled walk over `Render.findNode` — the view tree
    /// only — so iOS silently skipped the semantic-first rule the architecture
    /// documents, matched region labels case-sensitively where Android did not, and
    /// applied a different selector precedence. The semantic tree is derived here
    /// from the same capture, so both trees still describe one frame.
    func resolveTapPoint(_ params: [String: Any], snapshot: Snapshot) throws -> Point {
        try resolveTarget(params, snapshot: snapshot).point
    }

    func resolveTarget(
        _ params: [String: Any], snapshot: Snapshot
    ) throws -> SelectorResolution.Resolved {
        if let p = parsePoint(params["point"]) {
            return SelectorResolution.Resolved(point: p, source: "point", ref: nil)
        }
        let selector = selectorFromParams(params)
        guard let resolved = try SelectorResolution.resolve(
            snapshot: snapshot,
            semantic: SemanticTree.build(from: snapshot),
            selector: selector
        ) else {
            throw HelperError("could not resolve a tap point from selector \(selector.describe())"
                + Self.scrollHint(snapshot))
        }
        return try Self.withReach(snapshot, resolved)
    }

    /// Aim at the part of the target a touch can actually reach, or refuse.
    ///
    /// The Android helper's twin (`withReach` in HelperRuntime.kt): a frame is a
    /// LAYOUT box, and half of it can be below the display or scrolled under a
    /// sticky header while the tree still reports the whole rect. Refusing is right
    /// for a resolved SELECTOR — the tool computed the point and `act scroll-to`
    /// fixes it — while a coordinate the caller typed is left alone.
    static func withReach(
        _ snapshot: Snapshot, _ resolved: SelectorResolution.Resolved
    ) throws -> SelectorResolution.Resolved {
        guard let ref = resolved.ref, let reach = TapReach.of(snapshot, ref: ref) else { return resolved }
        guard let point = reach.point else { throw HelperError(reach.explain(ref)) }
        guard reach.adjusted else { return resolved }
        var adjusted = resolved
        adjusted.point = point
        adjusted.reachNote = reach.explain(ref)
        return adjusted
    }

    func settleRequested(_ params: [String: Any]) -> Bool { isTruthy(params["settle"]) }

    /// Re-resolve the tap target until it lands on the same point twice in a row —
    /// it has stopped moving — or the budget runs out.
    ///
    /// Resolution and dispatch are two steps, and a sheet or menu animating in moves
    /// between them: the captured rect is intermediate, so the synthesized touch can
    /// land on the neighbouring row. This is the same stabilize step `scroll-to`
    /// already performs, on the tap's own resolution path (no `isVisible` proxy).
    /// It never refuses to tap — a lapsed budget returns the freshest point flagged
    /// `stable = false`, which the caller reports as evidence.
    func settleTapPoint(
        _ pkg: String, _ params: [String: Any], first: Point
    ) -> SettledPoint {
        // Short default budget: on a settled screen the loop returns as soon as one
        // re-resolve agrees, so this bounds the animating case, not the common one.
        // An explicit `--settle` means "this IS animating" and gets the full 2s.
        let fallback = settleRequested(params) ? 2_000 : 800
        let budget = Double((params["settleTimeoutMs"] as? Int) ?? fallback) / 1000.0
        let deadline = Date().addingTimeInterval(budget)
        var previous = first
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            // A target that vanishes mid-settle (a menu dismissed under us) is not a
            // failure of the tap yet: report the freshest point and let the dispatch,
            // or the caller's own verification, be the judge.
            guard let snapshot = try? fetchSnapshot(pkg),
                  let current = try? resolveTapPoint(params, snapshot: snapshot) else {
                return SettledPoint(point: previous, stable: false)
            }
            if abs(current.x - previous.x) < 1, abs(current.y - previous.y) < 1 {
                return SettledPoint(point: current, stable: true)
            }
            previous = current
        }
        return SettledPoint(point: previous, stable: false)
    }

}
