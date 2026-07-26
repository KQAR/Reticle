import Foundation

func cmdDevices(_ c: HelperCalling, _ args: Args) throws {
    let r = try c.call("listDevices")
    let devices = (r["devices"] as? [[String: Any]]) ?? []
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success(["devices": devices])
        return
    }
    if devices.isEmpty { print("devices: none"); return }
    for d in devices { print("  \(d["serial"] ?? "?")  [\(d["state"] ?? "?")]") }
}

func cmdDoctor(_ c: HelperCalling, _ args: Args) throws {
    let ping = try c.call("ping")
    let devicesResponse = try c.call("listDevices")
    let devices = (devicesResponse["devices"] as? [[String: Any]]) ?? []
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success(["helper": ping, "devices": devices])
        return
    }
    print("helper: ok (cli version \(ping["version"] ?? "?"))")
    if devices.isEmpty { print("devices: none"); return }
    for d in devices { print("  \(d["serial"] ?? "?")  [\(d["state"] ?? "?")]") }
}

func cmdStatus(_ c: HelperCalling, _ args: Args) throws {
    let pkg = try args.require("package")
    let r = try c.call("status", ["package": pkg])
    let advisory = RuntimeProcessStateStore().observe(
        package: pkg,
        serial: serialOption(args),
        result: r
    )
    if let advisory {
        publishRuntimeAdvisoryIfDaemonIsRunning(package: pkg, target: platformTarget(args), advisory: advisory)
    }
    if JsonEnvelope.enabled(args) {
        var data = r
        data["package"] = pkg
        if let advisory {
            data["advisory"] = advisory.jsonObject
        }
        try JsonEnvelope.success(data)
        return
    }
    print("package: \(pkg)")
    print("running: \(r["running"] ?? false)\(r["pid"].map { " (pid=\($0))" } ?? "")")
    print("runtime: \(r["runtime"] ?? "unknown")")
    if let advisory {
        print("advisory: \(advisory.message)")
    }
}

func cmdInject(_ c: HelperCalling, _ args: Args) throws {
    let pkg = try args.require("package")
    var params: [String: Any] = ["package": pkg]
    let isIos = (args.option("target") ?? "android") == "ios"
    // On iOS the injectable is a dylib (resolved by IosHelperClient); the Android
    // payload dex only applies to the Android/JDWP path.
    if isIos {
        if let payload = args.option("payload-dex") { params["payloadDex"] = payload }
    } else {
        let devPayload = "reticle-agent/android/build/reticle-payload/reticle-agent-payload.jar"
        let payload = args.option("payload-dex")
            ?? (FileManager.default.fileExists(atPath: devPayload)
                ? FileManager.default.currentDirectoryPath + "/" + devPayload : nil)
        if let payload { params["payloadDex"] = payload }
    }
    let r = try c.call("inject", params)
    RuntimeProcessStateStore().record(package: pkg, serial: serialOption(args), result: r)
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success(r)
        return
    }
    print("runtime live: \(r["packageName"] ?? pkg) pid=\(r["pid"] ?? "?") port=\(r["port"] ?? "?") agent=\(r["agentVersion"] ?? "?")")
    if !isIos {
        // The JDWP handshake dead-zone on a freshly launched debug process is
        // most of inject's 30s+ wall clock; a linked agent skips all of it.
        print("tip: debug builds that link the reticle-agent AAR auto-start on launch — no inject needed")
    }
}

func cmdUiReport(_ c: HelperCalling, _ args: Args) throws {
    let pkg = try args.require("package")
    let outDir = args.option("output") ?? "reticle-report"
    let r = try c.call("uiReport", ["package": pkg])
    let fm = FileManager.default
    try fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    let pruned = pruneStaleReportArtifacts(in: outDir, fm: fm)

    for key in ["snapshot", "semantics", "compact"] {
        guard let tree = r[key] else { continue }
        let data = try JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: "\(outDir)/\(key).json"))
    }
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success([
            "output": outDir,
            "nodeCount": r["nodeCount"] ?? NSNull(),
            "compactItemCount": r["compactItemCount"] ?? NSNull(),
            "semanticNodeCount": r["semanticNodeCount"] ?? NSNull(),
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
    print("nodes: \(r["nodeCount"] ?? "?"), compact items: \(r["compactItemCount"] ?? "?"), semantic nodes: \(r["semanticNodeCount"] ?? "?")")
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

func cmdLaunch(_ c: HelperCalling, _ args: Args) throws {
    let pkg = try args.require("package")
    let r = try c.call("launch", ["package": pkg])
    RuntimeProcessStateStore().record(package: pkg, serial: serialOption(args), result: r)
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success(r)
        return
    }
    print("runtime live: \(r["packageName"] ?? pkg) pid=\(r["pid"] ?? "?") port=\(r["port"] ?? "?") agent=\(r["agentVersion"] ?? "?")")
}

@discardableResult
func cmdAct(_ c: HelperCalling, _ args: Args) throws -> Int32 {
    guard let gesture = args.positional(1) else { throw HelperError("act needs a gesture (tap/swipe/drag/scroll-to/type/hide-keyboard/wait)") }
    if gesture == "batch" {
        try cmdActBatch(c, args)
        return 0
    }
    if gesture == "wait" {
        return try cmdActWait(c, args)
    }
    let pkg = try args.require("package")
    var params: [String: Any] = ["gesture": gesture, "package": pkg]
    for k in ["test-id", "resource-id", "css", "ref", "point", "alias", "label", "region", "from", "to",
              "duration", "text", "container", "direction", "max-swipes"] {
        if let v = args.option(k) { params[selectorKey(k)] = v }
    }
    // `type --submit`: press the keyboard's action key after typing (agent
    // editor action on Android, HID Return on the iOS simulator).
    if let submit = args.option("submit"), submit != "false" { params["submit"] = true }
    // `tap --settle`: re-resolve the selector until its point stops moving before
    // dispatching, so a still-animating popup cannot make the touch land on its
    // neighbour. Opt-in, because it costs a poll loop on every tap.
    if let settle = args.option("settle"), settle != "false" { params["settle"] = true }
    if let t = args.option("settle-timeout") { params["settleTimeoutMs"] = Int(t) ?? 2000 }
    if let v = args.option("verify") { params["verify"] = v }
    if let t = args.option("verify-timeout") { params["verifyTimeoutMs"] = Int(t) ?? 2000 }
    if let out = args.option("trace-output") {
        params["traceOutput"] = out
    } else if let out = automaticSessionTraceOutput() {
        params["traceOutput"] = out
        params["traceAuto"] = true
    }
    if let t = args.option("trace-delay") { params["traceDelayMs"] = Int(t) ?? 250 }

    let r = try c.call("act", params)
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success(r)
        return 0
    }
    print(r.filter { $0.key != "verify" && $0.key != "trace" }.map { "\($0)=\($1)" }.sorted().joined(separator: " "))
    if let verify = r["verify"] as? [String: Any] { printVerify(verify) }
    if let trace = r["trace"] as? [String: Any] {
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
private func cmdActWait(_ c: HelperCalling, _ args: Args) throws -> Int32 {
    let pkg = try args.require("package")
    var params: [String: Any] = ["gesture": "wait", "package": pkg]
    // `point` and `alias` are forwarded even though a wait cannot use them: the
    // helper refuses each BY NAME ("a coordinate always resolves", "an alias
    // describes the screen a wait exists to watch change"). Dropping them here
    // would silently downgrade those to the generic "needs a predicate".
    for k in ["test-id", "resource-id", "css", "ref", "label", "for", "alias", "point"] {
        if let v = args.option(k) { params[selectorKey(k)] = v }
    }
    if let gone = args.option("gone"), gone != "false" { params["gone"] = true }
    if let idle = args.option("idle"), idle != "false" { params["idle"] = true }
    // `--text` on a wait means "contains this substring", not `type`'s "send this
    // text". Renamed on the wire so a batch step can never be read as a type.
    if let text = args.option("text") { params["textContains"] = text }
    if let t = args.option("timeout") { params["timeoutMs"] = Int(t) ?? 10_000 }
    if let q = args.option("quiet-for") { params["quietMs"] = Int(q) ?? 400 }

    let r = try c.call("act", params)
    let outcome = (r["outcome"] as? String) ?? "unknown"
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success(r)
    } else {
        printWait(r, outcome: outcome)
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

func cmdActBatch(_ c: HelperCalling, _ args: Args) throws {
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
        var params = rawStep
        let gesture = params["gesture"] as? String ?? ""
        guard !gesture.isEmpty else {
            throw HelperError("act batch step \(index + 1) is missing gesture")
        }
        params["package"] = params["package"] ?? pkg
        if let traceRoot, params["traceOutput"] == nil {
            params["traceOutput"] = URL(fileURLWithPath: traceRoot)
                .appendingPathComponent(String(format: "step-%02d-%@", index + 1, gesture))
                .path
        }
        if let delay = args.option("trace-delay"), params["traceDelayMs"] == nil {
            params["traceDelayMs"] = Int(delay) ?? 250
        }
        let result = try c.call("act", params)
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
        if let delayMs = batchInt(params["delayMs"]), delayMs > 0 {
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

func automaticSessionTraceOutput(discovery: DaemonDiscovery = DaemonDiscovery()) -> String? {
    guard let info = discovery.readLive() else { return nil }
    return discovery.traceDirectory(for: info).path
}

private func serialOption(_ args: Args) -> String? {
    args.option("serial").flatMap { $0 == "true" ? nil : $0 }
}
