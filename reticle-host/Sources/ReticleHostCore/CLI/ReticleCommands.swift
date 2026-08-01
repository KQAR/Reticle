import Foundation

func cmdDevices(_ backend: HostBackend, _ args: Args) throws {
    let devices = try backend.listDevices()
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success(["devices": devices.map(\.jsonObject)])
        return
    }
    if devices.isEmpty { print("devices: none"); return }
    for d in devices { print("  \(d.serial)  [\(d.state)]") }
}

func cmdDoctor(_ backend: HostBackend, _ args: Args) throws {
    let ping = try backend.ping()
    let devices = try backend.listDevices()
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success([
            "helper": ["pong": true, "version": ping.version],
            "devices": devices.map(\.jsonObject),
        ])
        return
    }
    print("helper: ok (cli version \(ping.version))")
    if devices.isEmpty { print("devices: none"); return }
    for d in devices { print("  \(d.serial)  [\(d.state)]") }
}

func cmdStatus(_ backend: HostBackend, _ args: Args) throws {
    let pkg = try args.require("package")
    let status = try backend.status(StatusRequest(package: pkg))
    let advisory = RuntimeProcessStateStore().observe(
        package: pkg,
        serial: serialOption(args),
        result: status.jsonObject
    )
    if let advisory {
        publishRuntimeAdvisoryIfDaemonIsRunning(package: pkg, target: platformTarget(args), advisory: advisory)
    }
    if JsonEnvelope.enabled(args) {
        var data = status.jsonObject
        data["package"] = pkg
        if let advisory {
            data["advisory"] = advisory.jsonObject
        }
        try JsonEnvelope.success(data)
        return
    }
    print("package: \(pkg)")
    print("running: \(status.running)\(status.pid.map { " (pid=\($0))" } ?? "")")
    print("runtime: \(status.runtime ?? "unknown")")
    if let advisory {
        print("advisory: \(advisory.message)")
    }
}

func cmdInject(_ backend: HostBackend, _ args: Args) throws {
    let pkg = try args.require("package")
    let isIos = (args.option("target") ?? "android") == "ios"
    var payload: String?
    // On iOS the injectable is a dylib (resolved by IosHelperClient); the Android
    // payload dex only applies to the Android/JDWP path.
    if isIos {
        payload = args.option("payload-dex")
    } else {
        let devPayload = "reticle-agent/android/build/reticle-payload/reticle-agent-payload.jar"
        payload = args.option("payload-dex")
            ?? (FileManager.default.fileExists(atPath: devPayload)
                ? FileManager.default.currentDirectoryPath + "/" + devPayload : nil)
    }
    // `--restart-under-debugger`: relax the input-dispatch ANR that can kill the app
    // while JDWP holds its main thread suspended. Opt-in, and the name says the
    // price: marking the debug app force-stops the target, so the app comes back on
    // its launch screen rather than the one you were driving.
    let started = try backend.inject(AppStartRequest(
        package: pkg, payload: payload, restartUnderDebugger: args.flag("restart-under-debugger")
    ))
    RuntimeProcessStateStore().record(package: pkg, serial: serialOption(args), result: started.jsonObject)
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success(started.jsonObject)
        return
    }
    print("runtime live: \(started.packageName) pid=\(started.pid.map(String.init) ?? "?") port=\(started.port.map(String.init) ?? "?") agent=\(started.agentVersion ?? "?")")
    if !isIos {
        // The JDWP handshake dead-zone on a freshly launched debug process is
        // most of inject's 30s+ wall clock; a linked agent skips all of it.
        print("tip: debug builds that link the reticle-agent AAR auto-start on launch — no inject needed")
    }
}

func cmdUiReport(_ backend: HostBackend, _ args: Args) throws {
    let pkg = try args.require("package")
    let outDir = args.option("output") ?? "reticle-report"
    let report = try backend.uiReport(PackageRequest(package: pkg))
    let fm = FileManager.default
    try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let pruned = pruneStaleReportArtifacts(in: outDir, fm: fm)

    for key in ["snapshot", "semantics", "compact"] {
        guard let tree = report.trees[key] else { continue }
        let data = try JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: "\(outDir)/\(key).json"))
    }
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success([
            "output": outDir,
            "nodeCount": report.nodeCount as Any? ?? NSNull(),
            "compactItemCount": report.compactItemCount as Any? ?? NSNull(),
            "semanticNodeCount": report.semanticNodeCount as Any? ?? NSNull(),
            "prunedStaleArtifacts": pruned,
            "files": [
                "snapshot": "\(outDir)/snapshot.json",
                "semantics": "\(outDir)/semantics.json",
                "compact": "\(outDir)/compact.json",
            ],
        ])
        return
    }
    print("wrote report to \(outDir)")
    print("nodes: \(report.nodeCount.map(String.init) ?? "?"), compact items: \(report.compactItemCount.map(String.init) ?? "?"), semantic nodes: \(report.semanticNodeCount.map(String.init) ?? "?")")
    if pruned > 0 {
        print("pruned \(pruned) stale artifact(s) from a prior report (use `ui screenshot` for a fresh frame)")
    }
}

func pruneStaleReportArtifacts(in dir: String, fm: FileManager) -> Int {
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return 0 }
    var removed = 0
    for name in entries {
        let isLegacy = name == "screenshot.png"
            || name == "accessibility.json"
            || (name.hasPrefix("screen") && name.hasSuffix(".png")
                && Int(name.dropFirst("screen".count).dropLast(".png".count)) != nil)
        guard isLegacy else { continue }
        if (try? fm.removeItem(atPath: "\(dir)/\(name)")) != nil { removed += 1 }
    }
    return removed
}

func cmdLaunch(_ backend: HostBackend, _ args: Args) throws {
    let pkg = try args.require("package")
    let started = try backend.launch(AppStartRequest(package: pkg))
    RuntimeProcessStateStore().record(package: pkg, serial: serialOption(args), result: started.jsonObject)
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success(started.jsonObject)
        return
    }
    print("runtime live: \(started.packageName) pid=\(started.pid.map(String.init) ?? "?") port=\(started.port.map(String.init) ?? "?") agent=\(started.agentVersion ?? "?")")
}

@discardableResult
func cmdAct(_ backend: HostBackend, _ args: Args) throws -> Int32 {
    guard let gesture = args.positional(1) else { throw HelperError("act needs a gesture (tap/swipe/drag/scroll-to/type/hide-keyboard/wait)") }
    if gesture == "batch" {
        try cmdActBatch(backend, args)
        return 0
    }
    if gesture == "wait" {
        return try cmdActWait(backend, args)
    }
    var request = ActRequest(
        gesture: gesture,
        package: try args.require("package"),
        selector: args.hostSelector(["test-id", "resource-id", "css", "ref", "point", "alias", "label", "region"])
    )
    request.from = args.option("from")
    request.to = args.option("to")
    request.duration = args.option("duration")
    request.text = args.option("text")
    request.container = args.option("container")
    request.direction = args.option("direction")
    request.maxSwipes = args.option("max-swipes")
    // `type --submit`: press the keyboard's action key after typing (agent
    // editor action on Android, HID Return on the iOS simulator).
    request.submit = args.flag("submit")
    // Every act watches the system Toast Queue: a text toast is in no window of
    // the app, so an action answered by one is otherwise indistinguishable from
    // one that hit nothing. `--no-toast-probe` opts out.
    request.noToastProbe = args.flag("no-toast-probe")
    // `type --type-delay <ms>`: pace the keystrokes for a field that loses them
    // out of the default single burst. `act type` reads the field back either
    // way and says what actually landed.
    request.typeDelayMs = try args.intOption("type-delay")
    // A selector tap re-resolves its point before dispatching by default, so a
    // rect made stale by an earlier relayout cannot send the touch to the
    // neighbouring control. `--settle` raises the budget for a target that is
    // genuinely animating in; `--no-settle` opts out of the confirm entirely.
    request.settle = args.flag("settle")
    request.noSettle = args.flag("no-settle")
    request.settleTimeoutMs = try args.intOption("settle-timeout")
    request.verify = args.option("verify")
    request.verifyTimeoutMs = try args.intOption("verify-timeout")
    if let out = args.option("trace-output") {
        request.traceOutput = out
    } else if let out = automaticSessionTraceOutput() {
        request.traceOutput = out
        request.traceAuto = true
    }
    request.traceDelayMs = try args.intOption("trace-delay")

    let outcome = try backend.act(request)
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success(outcome.raw)
        return 0
    }
    print(outcome.displayFields.map { "\($0)=\($1)" }.sorted().joined(separator: " "))
    if let verify = outcome.verify { printVerify(verify) }
    if let trace = outcome.trace {
        printTrace(trace)
        publishTraceIfDaemonIsRunning(trace)
    }
    return 0
}

/// `act wait`: block until a stated predicate holds, then report a three-state
/// outcome with its evidence.
///
/// The outcome is a FIELD (`outcome`), and `--json` carries it under a normal
/// `{"ok": true, ...}` envelope even on a timeout — a predicate that did not come
/// true is an observation, not a tool failure. The exit code is an opt-in lossy
/// projection of that field for shell/CI callers (`--strict`), never the primary
/// channel: a non-zero exit reads as "the command broke" to an agent driving this
/// through a shell, which is worse than a clear line on stdout.
private func cmdActWait(_ backend: HostBackend, _ args: Args) throws -> Int32 {
    var request = ActRequest(
        gesture: "wait",
        package: try args.require("package"),
        // `point` and `alias` are forwarded even though a wait cannot use them: the
        // backend refuses each BY NAME ("a coordinate always resolves", "an alias
        // describes the screen a wait exists to watch change"). Dropping them here
        // would silently downgrade those to the generic "needs a predicate".
        selector: args.hostSelector(["test-id", "resource-id", "css", "ref", "label", "alias", "point"])
    )
    request.waitFor = args.option("for")
    request.waitGone = args.flag("gone")
    request.waitIdle = args.flag("idle")
    // `--text` on a wait means "contains this substring", not `type`'s "send this
    // text". Renamed on the wire so a batch step can never be read as a type.
    request.textContains = args.option("text")
    request.timeoutMs = try args.intOption("timeout")
    request.quietMs = try args.intOption("quiet-for")

    let result = try backend.act(request)
    let outcome = result.outcome ?? "unknown"
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success(result.raw)
    } else {
        printWait(result.raw, outcome: outcome)
    }
    guard let strict = args.option("strict"), strict != "false" else { return 0 }
    switch outcome {
    case "resolved": return 0
    case "absent": return 3
    // Distinct from 3 on purpose: an agent may act on `absent` ("this is not
    // there"), but must only switch tactics on `unknowable` ("I could not see").
    case "unknowable": return 4
    default: return 1
    }
}

private func printWait(_ r: [String: Any], outcome: String) {
    let predicate = (r["predicate"] as? String) ?? "?"
    let elapsed = intOf(r["elapsedMs"]) ?? 0
    let polls = intOf(r["polls"]) ?? 0
    let changes = intOf(r["treeChanges"]) ?? 0
    let verb = outcome == "resolved" ? "in" : "after"
    var head = "wait \(predicate): \(outcome.uppercased()) \(verb) \(elapsed)ms (\(polls) polls, \(changes) tree changes)"
    if let source = r["source"] as? String { head += " source=\(source)" }
    if let ref = r["ref"] as? String { head += " ref=\(ref)" }
    print(head)
    if let text = r["observedText"] as? String { print("  observed: \"\(text)\"") }
    if let reasons = r["reasons"] as? [Any], !reasons.isEmpty {
        print("  reasons: \(reasons.map { "\($0)" }.joined(separator: ", "))")
    }
    if let caveats = r["caveats"] as? [Any], !caveats.isEmpty {
        print("  caveats: \(caveats.map { "\($0)" }.joined(separator: ", "))")
    }
    if let next = r["next"] as? [Any], !next.isEmpty {
        for step in next { print("  next: \(step)") }
    }
}

private func intOf(_ value: Any?) -> Int? {
    switch value {
    case let int as Int: return int
    case let num as NSNumber: return num.intValue
    case let str as String: return Int(str)
    default: return nil
    }
}

func cmdActBatch(_ backend: HostBackend, _ args: Args) throws {
    let pkg = try args.require("package")
    let file = try args.require("file")
    let data = try Data(contentsOf: URL(fileURLWithPath: file))
    let steps = try actionBatchSteps(from: data)
    guard !steps.isEmpty else {
        throw HelperError("act batch file must contain at least one step")
    }
    let traceRoot = args.option("trace-output")
    var results: [[String: Any]] = []
    for (index, rawStep) in steps.enumerated() {
        let gesture = rawStep["gesture"] as? String ?? ""
        guard !gesture.isEmpty else {
            throw HelperError("act batch step \(index + 1) is missing gesture")
        }
        var request = ActRequest.fromBatchStep(rawStep, defaultPackage: pkg)
        if let traceRoot, request.traceOutput == nil {
            request.traceOutput = URL(fileURLWithPath: traceRoot)
                .appendingPathComponent(String(format: "step-%02d-%@", index + 1, gesture))
                .path
        }
        if let delay = try args.intOption("trace-delay"), request.traceDelayMs == nil {
            request.traceDelayMs = delay
        }
        let result = try backend.act(request).raw
        // A `wait` step is the only step that can report a non-fatal
        // disappointment: it never throws, because a predicate that did not come
        // true is an observation. But inside a BATCH the usual intent is a gate —
        // "do not run the next step until the screen is ready" — so a step may opt
        // into stopping the batch with `"strict": true`. Left off, the batch
        // continues and the outcome is just recorded in the step's result.
        if gesture == "wait", batchFlag(rawStep["strict"]) {
            let outcome = (result["outcome"] as? String) ?? "unknown"
            if outcome != "resolved" {
                let predicate = (result["predicate"] as? String) ?? "?"
                let why = (result["reasons"] as? [Any])?.map { "\($0)" }.joined(separator: ", ")
                throw HelperError(
                    "batch step \(index + 1) wait (\(predicate)) ended \(outcome.uppercased())"
                        + (why?.isEmpty == false ? " — \(why!)" : "")
                        + ". The step was marked strict, so the batch stops here."
                )
            }
        }
        results.append(["index": index + 1, "gesture": gesture, "result": result])
        if JsonEnvelope.enabled(args) == false {
            print("step \(index + 1) \(gesture): \(compactResultLine(result))")
            if let verify = result["verify"] as? [String: Any] { printVerify(verify) }
            if let trace = result["trace"] as? [String: Any] {
                printTrace(trace)
                publishTraceIfDaemonIsRunning(trace)
            }
        }
        if let delayMs = batchInt(rawStep["delayMs"]), delayMs > 0 {
            Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
        }
    }
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success(["count": results.count, "steps": results])
    }
}

func actionBatchSteps(from data: Data) throws -> [[String: Any]] {
    let value = try JSONSerialization.jsonObject(with: data)
    guard let array = value as? [[String: Any]] else {
        throw HelperError("act batch file must be a JSON array of step objects")
    }
    return array
}

private func compactResultLine(_ result: [String: Any]) -> String {
    result
        .filter { $0.key != "verify" && $0.key != "trace" }
        .map { "\($0)=\($1)" }
        .sorted()
        .joined(separator: " ")
}

/// Interpret a batch step's boolean (`true`, `"true"`, `1`).
private func batchFlag(_ value: Any?) -> Bool {
    switch value {
    case let b as Bool: return b
    case let s as String: return s == "true" || s == "1"
    case let n as NSNumber: return n.boolValue
    default: return false
    }
}

private func batchInt(_ value: Any?) -> Int? {
    switch value {
    case let int as Int:
        return int
    case let number as NSNumber:
        return number.intValue
    case let double as Double:
        return Int(double)
    default:
        return nil
    }
}

func printVerify(_ v: [String: Any]) {
    let sel = v["selector"] as? String ?? "?"
    let changed = (v["changed"] as? Bool) ?? false
    let changes = (v["changes"] as? [[String: Any]]) ?? []
    if let note = v["note"] as? String {
        print("verify \(sel): \(note)")
    } else if changed {
        print("verify \(sel): changed (\(changes.count) field\(changes.count == 1 ? "" : "s"))")
        for ch in changes {
            let field = ch["field"] as? String ?? "?"
            let before = ch["before"].map { "\($0)" } ?? "null"
            let after = ch["after"].map { "\($0)" } ?? "null"
            print("  \(field): \(before) -> \(after)")
        }
    } else {
        print("verify \(sel): no change")
    }
}

func printTrace(_ v: [String: Any]) {
    let path = v["path"] as? String ?? "?"
    let changes = v["changeCount"] ?? "?"
    print("trace: wrote \(path) (\(changes) change(s))")
}

private func publishTraceIfDaemonIsRunning(_ trace: [String: Any]) {
    guard
        let dir = trace["path"] as? String,
        let manifest = trace["manifest"] as? String
    else { return }
    let path = URL(fileURLWithPath: dir).appendingPathComponent(manifest).path
    if case .failure(let error) = DaemonEventPublisher().publishActionTrace(path: path) {
        FileHandle.standardError.write(Data("warning: could not publish trace to reticle serve: \(error)\n".utf8))
    }
}

/// The event-bus target prefix for the selected platform (`android:` / `ios:`).
func platformTarget(_ args: Args) -> String {
    (args.option("target") ?? "android")
}

private func publishRuntimeAdvisoryIfDaemonIsRunning(package: String, target: String, advisory: RuntimeProcessAdvisory) {
    let event = EventPostRequest(
        target: "\(target):\(package)",
        source: "runtime",
        type: "runtime.advisory",
        payload: advisory.jsonObject.mapValues(JSONValue.fromAny)
    )
    if case .failure(let error) = DaemonEventPublisher().publishEvent(event) {
        FileHandle.standardError.write(Data("warning: could not publish runtime advisory to reticle serve: \(error)\n".utf8))
    }
}

/// Where an action records when the caller did not pass `--trace-output`.
///
/// A live `reticle serve` session wins, so traces keep landing beside that
/// session's events and reaching its panel. With no daemon this falls back to an
/// auto session instead of recording nothing — the ad-hoc runs were the ones
/// leaving no evidence behind, and they are the ones most worth reconstructing.
///
/// Set `RETICLE_NO_AUTO_TRACE=1` to opt out and go back to recording only when
/// asked. Nothing here can fail an action: on any error the action still
/// dispatches, just unrecorded.
func automaticSessionTraceOutput(
    discovery: DaemonDiscovery = DaemonDiscovery(),
    autoSession: AutoSession = AutoSession(),
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> String? {
    if let info = discovery.readLive() {
        return discovery.traceDirectory(for: info).path
    }
    if isTruthyEnvironmentFlag(environment["RETICLE_NO_AUTO_TRACE"]) { return nil }
    guard let dir = autoSession.currentTraceDirectory() else { return nil }
    // Prune after choosing, and never the session just chosen.
    let current = dir.deletingLastPathComponent().lastPathComponent
    let removed = autoSession.prune(excluding: current)
    if !removed.isEmpty {
        // Evidence disappearing quietly is its own small dishonesty.
        FileHandle.standardError.write(Data(
            "note: pruned \(removed.count) old auto-recorded session(s): \(removed.joined(separator: ", "))\n".utf8
        ))
    }
    return dir.path
}

private func isTruthyEnvironmentFlag(_ value: String?) -> Bool {
    guard let value = value?.lowercased() else { return false }
    return value == "1" || value == "true" || value == "yes"
}

private func serialOption(_ args: Args) -> String? {
    args.option("serial").flatMap { $0 == "true" ? nil : $0 }
}
