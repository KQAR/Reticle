import Foundation
import ReticleHostShared
import ReticleProtocol

// The gestures themselves: what `act <gesture>` does once the target is known.
//
// Split out of `IosHelperClient` for the reason the scroll-to and verify halves
// already were — it had grown back to four concerns in one type, and this is the
// one that grows every time a gesture learns a new piece of evidence. What stays
// behind is the `HostBackend` surface; what lives here is `performAct`'s switch and
// the per-gesture helpers only it calls (the trace merge, the HID precondition, the
// in-process activation).
//
// `private` becomes module-internal where a member is now called from another file
// in this same split; a Swift extension cannot see another file's `private`.
extension IosHelperClient {
    // MARK: - Actions (input synthesis)

    /// Runs one gesture, wrapping it in `--verify` before/after node-state diffing
    /// when requested — the iOS analogue of the Android helper's `HelperVerify`,
    /// producing the same `verify` result shape the host's `printVerify` renders.
    /// Previously iOS silently accepted and dropped `--verify`, so an agent believed
    /// it had checked a post-condition it never checked.
    public func act(_ request: ActRequest) async throws -> ActOutcome {
        ActOutcome(raw: try await act(request.wireParams))
    }

    /// The gesture handler still reads a parameter dictionary, and `act` is the one
    /// method where that is not just inertia: `act batch` builds steps from user
    /// JSON, and the modifiers are shared across gestures. The typed entry point
    /// above is what callers see; converting this body is tracked separately so the
    /// interface change and the internal one are reviewable apart.
    func act(_ params: [String: Any]) async throws -> [String: Any] {
        // `wait` refuses an alias for its own reason (an alias describes the screen a
        // wait exists to watch change) and gets there first; this catches every other
        // gesture, for which the alias simply has nothing to resolve against.
        if (params["gesture"] as? String) != "wait" {
            try Self.rejectAlias(params["alias"] as? String, command: "act \((params["gesture"] as? String) ?? "tap")")
        }
        guard let watch = try verifyWatchSelector(params) else {
            return try await performAct(params)
        }
        let pkg = try bundleId(params)
        let before = await captureVerifyState(pkg, watch)
        var result = try await performAct(params)
        result["verify"] = await pollVerify(pkg, watch, before: before, params: params)
        return result
    }

    func performAct(_ params: [String: Any]) async throws -> [String: Any] {
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
            let before = await tracer?.capture()
            let result = try await activate(pkg, params)
            return try await finishTrace(tracer, before, settleMs, gesture: "activate", selector: selector,
                                   point: nil, source: result["via"] as? String, ref: result["ref"] as? String,
                                   result: result)
        }

        // In-process keyboard dismissal: no HID surface needed, so it works on
        // devices and simulators alike, and reports the settled before/after
        // state straight from the agent.
        if gesture == "hideKeyboard" || gesture == "hide-keyboard" {
            let before = await tracer?.capture()
            let obj: [String: Any]
            do {
                let (data, _) = try await IosAgentHTTP(bundleId: pkg).post(Endpoints.keyboardHide, body: Data())
                obj = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            } catch {
                throw HelperError("hide-keyboard needs the in-process agent (is the runtime up?): \(error)")
            }
            let keyboard = obj["keyboard"] as? [String: Any]
            return try await finishTrace(tracer, before, settleMs, gesture: "hideKeyboard", selector: nil,
                                   point: nil, source: "agent", ref: nil,
                                   result: ["gesture": "hideKeyboard", "via": "agent resignFirstResponder",
                                            "wasVisible": obj["wasVisible"] ?? false,
                                            "keyboardVisible": keyboard?["visible"] ?? false])
        }

        // The one gesture that dispatches no input: it only observes, so like
        // `hide-keyboard` it needs no HID surface and works on real devices too.
        if gesture == "wait" {
            let predicate = try IosWaitRunner.predicate(from: params)
            let runner = IosWaitRunner(fetch: { try await self.fetchSnapshot(pkg) })
            return await try runner.run(
                predicate: predicate,
                timeoutMs: (params["timeoutMs"] as? Int) ?? WaitSchedule.defaultTimeoutMs,
                quietMs: (params["quietMs"] as? Int) ?? WaitSchedule.defaultQuietMs
            )
        }

        // HID (real touch/keyboard) needs a booted simulator; a real device has no
        // host-reachable HID input surface.
        let simUdid = await try? Simctl.resolveUdid(serial)

        switch gesture {
        case "tap":
            // A real device now HAS a touch surface: the agent synthesizes the touch
            // inside the app (see `IosTouchSurface`), so a coordinate tap, a
            // `--region` tap and a selector tap all behave as they do on a simulator
            // — hit-testing, gesture recognizers and scroll views included. Only when
            // that surface is absent (an older agent, or the private UIKit surface
            // gone) does a SELECTOR tap fall back to in-process activation, which
            // fires an action instead of delivering a touch.
            // `map` cannot carry an await, so the optional is unwrapped first.
            let deviceIsSim: Bool
            if let simUdid { deviceIsSim = await Simctl.isSimulator(simUdid) } else { deviceIsSim = false }
            if !deviceIsSim, await !IosTouchSurface.agentTouchAvailable(pkg) {
                if params["point"] != nil {
                    throw HelperError("point taps need a touch surface; this device has none "
                        + "(no agent `POST /touch`), so name the target and use `act activate`")
                }
                let before = await tracer?.capture()
                var result = try await activate(pkg, params)
                // `--settle` is about a coordinate going stale between resolve and
                // dispatch; in-process activation does both in one step, so there is
                // nothing to wait out. Say so rather than reporting a settle that
                // never ran.
                if settleRequested(params) {
                    result["settleSkipped"] = "activation resolves and dispatches in-process"
                }
                return try await finishTrace(tracer, before, settleMs, gesture: "tap", selector: selector,
                                       point: nil, source: result["via"] as? String, ref: result["ref"] as? String,
                                       result: result)
            }
            let surface = try await IosTouchSurface.resolve(simUdid: simUdid, bundleId: pkg, gesture: "tap")
            let snapshot = try await fetchSnapshot(pkg)
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
                let settled = await settleTapPoint(pkg, params, first: point)
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
            let before = await tracer?.capture()
            try await surface.tap(x: point.x, y: point.y, screen: screen)
            var result: [String: Any] = [
                "gesture": "tap", "via": surface.describe, "x": point.x, "y": point.y,
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
            // The app was not the active one when this was dispatched, which on a
            // device means another PROCESS's window — a system prompt — holds input.
            // `ui compact` has always said so on its first line; the action said
            // nothing, so a tap into an inactive app read as an ordinary success and
            // the empty diff that followed got blamed on the target. Measured: a
            // StoreKit account prompt over the app under test made every tap on its
            // content inert while the dispatch kept reporting success.
            if let inactive = inactiveWarning(snapshot) { result["warning"] = inactive }
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
            // A DOM rect folded to a point outside the web view that draws it:
            // impossible for a correct fold, and silent until now — the tap
            // dispatches at the reported centre and reports settled=1.
            if let ref = target.ref, let snapshot = before?.snapshot,
               let complaint = DomRectCheck.outsideHost(snapshot, ref: ref) {
                result["rectSuspect"] = complaint
            }
            // And where the touch ACTUALLY landed, according to the page — the one
            // answer a tap has that is not Reticle's own arithmetic, so it is the only
            // one that can catch a fold that is wrong by an amount nothing else can
            // judge. Quiet on every ordinary tap. Only for the HID path: `activate`
            // dispatches on the element itself and uses no coordinate to be wrong.
            if !rawPoint, let landing = await domTapLanding(pkg, params, target: target) {
                result["landed"] = landing
            }
            return try await finishTrace(tracer, before, settleMs, gesture: "tap", selector: selector,
                                   point: point, source: target.source, ref: target.ref,
                                   result: result)
        case "swipe", "drag":
            let surface = try await IosTouchSurface.resolve(simUdid: simUdid, bundleId: pkg, gesture: gesture)
            guard let from = parsePoint(params["from"]), let to = parsePoint(params["to"]) else {
                throw HelperError("\(gesture) needs --from x,y and --to x,y")
            }
            let snapshot = try await fetchSnapshot(pkg)
            let screen = (snapshot.screen.size.width, snapshot.screen.size.height)
            let duration = Double((params["duration"] as? String) ?? "") ?? (gesture == "drag" ? 600 : 250)
            let before = await tracer?.capture()
            try await surface.swipe(from: (from.x, from.y), to: (to.x, to.y), screen: screen, durationMs: duration)
            return try await finishTrace(tracer, before, settleMs, gesture: gesture, selector: selector,
                                   point: from, source: "point", ref: nil,
                                   result: ["gesture": gesture, "via": surface.describe,
                                            "from": "\(from.x),\(from.y)", "to": "\(to.x),\(to.y)"])
        case "wheel":
            // Refused BY NAME rather than half-implemented. The Android gesture
            // converges on the wheel's own published value; on iOS a `UIPickerView`
            // publishes no equivalent yet (its selection is an a11y region, its row
            // pitch is not captured) — but it does something Android cannot: it builds
            // a real subview per visible row, so the value beside the selection IS a
            // node and a label tap selects it. Naming that is more use than a loop
            // that cannot check itself.
            throw HelperError(
                "act wheel is Android-only for now: it converges on the value a "
                    + "`NumberPicker` publishes, and a UIPickerView publishes no such reading yet. "
                    + "On iOS a wheel's VISIBLE rows are real nodes — `act tap --label \"<value>\"` "
                    + "selects one, and `ui regions` reports each column's current value; for a value "
                    + "that is off screen, swipe the column and re-read that region."
            )
        case "scroll-to", "scrollTo":
            // The gesture a device needed most: a lazy list's unrealized row has no
            // node until something scrolls it into view, and activation cannot scroll.
            let surface = try await IosTouchSurface.resolve(simUdid: simUdid, bundleId: pkg, gesture: "scroll-to")
            return try await scrollTo(pkg, params, surface: surface)
        case "type":
            guard let text = params["text"] as? String else { throw HelperError("type needs --text") }
            // No HID surface — a real device (whose `--serial` is a hardware ECID,
            // not a simulator udid), or a simulator whose private SimulatorKit
            // layout does not match — so type from INSIDE the app instead:
            // `insertText` through the agent, the same entry point the system
            // keyboard uses. The other gestures have to fail without HID; typing
            // does not, so it takes this route and says which one it took rather
            // than refusing work it can still do.
            //
            // `isSimulator` is the check that matters, and it was added because the
            // device suite caught the alternative being wrong: with no `--serial`,
            // `resolveUdid` falls back to the BOOTED SIMULATOR, so a device run
            // dispatched its keystrokes at the simulator's screen and reported
            // `via=hid` while the phone's field stayed empty.
            let isSim: Bool
            if let simUdid { isSim = await Simctl.isSimulator(simUdid) } else { isSim = false }
            let hidUnavailable = isSim ? !IosInputBackend(udid: simUdid!).isAvailable() : true
            guard let udid = simUdid, isSim, !hidUnavailable else {
                let before = await tracer?.capture()
                var result = try await typeInProcess(pkg, params, text: text)
                if isSim, hidUnavailable { result["hid"] = "unavailable — typed in-process instead" }
                return try await finishTrace(tracer, before, settleMs, gesture: "type", selector: selector,
                                       point: nil, source: result["focusedVia"] as? String,
                                       ref: result["ref"] as? String, result: result)
            }
            // The app must actually be on THAT simulator's screen. HID goes to the
            // screen, not to the process Reticle is talking to — and the agent is
            // reached over loopback, which a real device shares through a USB
            // tunnel, so "healthy" says nothing about where the keys will land.
            guard await Simctl.isAppInstalled(udid: udid, bundleId: pkg) else {
                throw HelperError(
                    "\(pkg) is not installed on simulator \(udid), so HID keystrokes would go to "
                    + "whatever IS on that screen. If you meant a real device, pass its hardware "
                    + "ECID as --serial (`idevice_id -l`) — typing then goes through the agent."
                )
            }
            let before = await tracer?.capture()
            // If the caller named a target field, tap it first so the text lands
            // in THAT field — HID typing and clipboard paste both go to whatever
            // currently holds focus, so `type --test-id foo` otherwise silently
            // typed into the wrong (or no) field. Mirrors the Android helper's
            // focus-tap; with no target, type into the current focus.
            var focusedVia: String? = nil
            var focusPoint: Point? = nil
            if selector != nil {
                let snapshot = try await fetchSnapshot(pkg)
                let screen = (snapshot.screen.size.width, snapshot.screen.size.height)
                let point = try resolveTapPoint(params, snapshot: snapshot)
                try IosInputBackend(udid: udid).tap(x: point.x, y: point.y, screen: screen)
                focusPoint = point
                // Give the tapped field a beat to take focus before dispatching
                // text (the Android helper settles 200ms for the same reason).
                try? await Task.sleep(for: .seconds(0.2))
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
                let outcome = try await clearFocusedField(pkg, udid: udid, params: params)
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
                // `--type-delay <ms>`: one key event per character with a gap, for a
                // field whose formatter drops keystrokes it receives in one burst.
                // The flag reached here and did nothing before — the same silent-flag
                // defect `--clear` had; Android has honoured it all along.
                if let gap = typeDelayMs(params), gap > 0 {
                    for character in text {
                        try IosInputBackend(udid: udid).type(String(character))
                        try? await Task.sleep(for: .seconds(Double(gap)) / 1000.0)
                    }
                    via = "hid (paced \(gap)ms)"
                } else {
                    try IosInputBackend(udid: udid).type(text)
                    via = "hid"
                }
            } else {
                // The HID keyboard can't emit non-ASCII (CJK / emoji / accented).
                // Stage it on the clipboard via the in-process agent, then Cmd+V —
                // the iOS analogue of Android's clipboard + KEYCODE_PASTE path.
                // Pastes into the current focus — the focus-tap above (or the
                // caller) must have put the caret in the right field.
                do {
                    try await IosAgentHTTP(bundleId: pkg).post(Endpoints.clipboard, body: Data(text.utf8))
                } catch {
                    throw HelperError("could not stage non-ASCII text on the clipboard (is the agent running?): \(error)")
                }
                // The agent sets UIPasteboard on the main thread asynchronously;
                // give it a beat to land before pasting.
                try? await Task.sleep(for: .seconds(0.12))
                try IosInputBackend(udid: udid).paste()
                via = "clipboard paste"
            }
            var result: [String: Any] = ["gesture": "type", "via": via, "text": text]
            if via == "clipboard paste", let gap = typeDelayMs(params), gap > 0 {
                // Say so rather than let a paced-typing request read as honoured:
                // a paste lands the whole string in one event, so there is nothing
                // to pace.
                result["typeDelayIgnored"] = "non-ASCII text pastes in one event"
            }
            if let clearedSummary { result["cleared"] = clearedSummary }
            if let cleared { result["clearDetail"] = cleared }
            if let focusedVia { result["focusedVia"] = focusedVia }
            // `type --submit`: press Return after the text lands. The HID
            // bridge maps '\n' to the Return usage, which triggers the focused
            // field's return-key action (textFieldShouldReturn / onSubmitEditing).
            if isTruthy(params["submit"]) {
                try? await Task.sleep(for: .seconds(0.15))
                try IosInputBackend(udid: udid).type("\n")
                result["submit"] = ["via": "hid return"]
            }
            // Opportunistic post-type keyboard state (typing almost always
            // leaves the keyboard covering the bottom of the screen); omitted
            // when the agent can't answer — typing must not fail over it.
            if let visible = (try? await IosAgentHTTP(bundleId: pkg).getJSONObject(Endpoints.keyboard))?["visible"] as? Bool {
                result["keyboardVisible"] = visible
            }
            return try await finishTrace(tracer, before, settleMs, gesture: "type", selector: selector,
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
    ) async throws -> [String: Any] {
        guard let tracer, let before else { return result }
        var out = result
        out["trace"] = try await tracer.write(
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
    ///
    /// `refused` throws — nothing was dispatched, which IS a tool failure.
    /// `unconfirmed` does NOT: the activation was dispatched and the target
    /// answered `false`, which UIKit also does for activations it performed, so
    /// throwing here both hid a real side effect behind `ok:false` AND skipped the
    /// two channels that could have settled it — `performAct` never returned, so
    /// `--verify` recorded nothing and `--trace-output` wrote no package. The
    /// outcome is a FIELD instead (the rule `act wait` already follows), and the
    /// warning names the flag that answers the question.
    func activate(_ pkg: String, _ params: [String: Any]) async throws -> [String: Any] {
        let request = ActivationRequest(selector: selectorFromParams(params))
        let body = try ReticleJSON.encodeWire(request)
        let (data, _) = try await IosAgentHTTP(bundleId: pkg).post(Endpoints.activate, body: body)
        let r = try ReticleJSON.decode(ActivationResult.self, from: data)
        if r.resolvedOutcome == .refused {
            throw HelperError("activation failed: \(r.message ?? "unknown") (ref=\(r.ref ?? "?"))")
        }
        var out: [String: Any] = [
            "gesture": "activate",
            "activated": r.activated,
            "outcome": r.resolvedOutcome.rawValue,
            "via": r.via ?? "sendActions",
        ]
        if let ref = r.ref { out["ref"] = ref }
        if let tn = r.typeName { out["typeName"] = tn }
        if r.resolvedOutcome == .unconfirmed {
            out["warning"] = r.message ?? "unconfirmed_activation"
        }
        return out
    }
}
