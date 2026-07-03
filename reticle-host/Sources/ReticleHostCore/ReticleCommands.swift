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
        publishRuntimeAdvisoryIfDaemonIsRunning(package: pkg, advisory: advisory)
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
    let devPayload = "reticle-agent/android/build/reticle-payload/reticle-agent-payload.jar"
    let payload = args.option("payload-dex")
        ?? (FileManager.default.fileExists(atPath: devPayload)
            ? FileManager.default.currentDirectoryPath + "/" + devPayload : nil)
    if let payload { params["payloadDex"] = payload }
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
    guard let gesture = args.positional(1) else { throw HelperError("act needs a gesture (tap/swipe/drag/type)") }
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

private func publishRuntimeAdvisoryIfDaemonIsRunning(package: String, advisory: RuntimeProcessAdvisory) {
    let event = EventPostRequest(
        target: "android:\(package)",
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
