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

func cmdAct(_ c: HelperCalling, _ args: Args) throws {
    guard let gesture = args.positional(1) else { throw HelperError("act needs a gesture (tap/swipe/drag/type/hide-keyboard)") }
    if gesture == "batch" {
        try cmdActBatch(c, args)
        return
    }
    let pkg = try args.require("package")
    var params: [String: Any] = ["gesture": gesture, "package": pkg]
    for k in ["test-id", "resource-id", "css", "ref", "point", "alias", "region", "from", "to", "duration", "text"] {
        if let v = args.option(k) { params[selectorKey(k)] = v }
    }
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
        return
    }
    print(r.filter { $0.key != "verify" && $0.key != "trace" }.map { "\($0)=\($1)" }.sorted().joined(separator: " "))
    if let verify = r["verify"] as? [String: Any] { printVerify(verify) }
    if let trace = r["trace"] as? [String: Any] {
        printTrace(trace)
        publishTraceIfDaemonIsRunning(trace)
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
