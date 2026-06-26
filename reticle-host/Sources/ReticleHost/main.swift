import Foundation

// reticle-host — Swift host CLI. Drives Android entirely through the Kotlin
// `reticle helper` over the JSONL RPC contract; owns no device code itself.
//
// Usage:
//   reticle-host <command> [options]
//
// Commands:
//   doctor                          device readiness via the helper
//   devices                         list attached devices
//   status   --package <pkg>        runtime health for a package
//   inject   --package <pkg>        inject the runtime over JDWP (via helper)
//   ui report --package <pkg> [--output <dir>]   capture + write report files
//
// Resolution of the Kotlin helper launcher (first hit wins):
//   1. $RETICLE_LAUNCHER
//   2. ./reticle-cli/build/install/reticle/bin/reticle   (dev layout)
// Pass --launcher to override.

struct Args {
    private var positionals: [String] = []
    private var options: [String: String] = [:]
    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    options[key] = argv[i + 1]; i += 2
                } else { options[key] = "true"; i += 1 }
            } else { positionals.append(a); i += 1 }
        }
    }
    func positional(_ idx: Int) -> String? { idx < positionals.count ? positionals[idx] : nil }
    func option(_ name: String) -> String? { options[name] }
    func require(_ name: String) throws -> String {
        guard let v = options[name] else { throw HelperError("missing required --\(name)") }
        return v
    }
}

func resolveLauncher(_ args: Args) -> String? {
    if let explicit = args.option("launcher") { return explicit }
    if let env = ProcessInfo.processInfo.environment["RETICLE_LAUNCHER"] { return env }
    let dev = "reticle-cli/build/install/reticle/bin/reticle"
    return FileManager.default.fileExists(atPath: dev) ? dev : nil
}

func printJSON(_ obj: Any) {
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

// --- command handlers --------------------------------------------------------

func cmdDevices(_ c: HelperClient) throws {
    let r = try c.call("listDevices")
    let devices = (r["devices"] as? [[String: Any]]) ?? []
    if devices.isEmpty { print("devices: none"); return }
    for d in devices { print("  \(d["serial"] ?? "?")  [\(d["state"] ?? "?")]") }
}

func cmdDoctor(_ c: HelperClient) throws {
    let ping = try c.call("ping")
    print("helper: ok (cli version \(ping["version"] ?? "?"))")
    try cmdDevices(c)
}

func cmdStatus(_ c: HelperClient, _ args: Args) throws {
    let pkg = try args.require("package")
    let r = try c.call("status", ["package": pkg])
    print("package: \(pkg)")
    print("running: \(r["running"] ?? false)\(r["pid"].map { " (pid=\($0))" } ?? "")")
    print("runtime: \(r["runtime"] ?? "unknown")")
}

func cmdInject(_ c: HelperClient, _ args: Args) throws {
    let pkg = try args.require("package")
    var params: [String: Any] = ["package": pkg]
    // Make the payload location explicit — the spike showed cwd-relative
    // resolution is a trap when the host spawns the helper from elsewhere.
    let devPayload = "reticle-agent/android/build/reticle-payload/reticle-agent-payload.jar"
    let payload = args.option("payload-dex")
        ?? (FileManager.default.fileExists(atPath: devPayload)
            ? FileManager.default.currentDirectoryPath + "/" + devPayload : nil)
    if let payload { params["payloadDex"] = payload }
    let r = try c.call("inject", params)
    print("runtime live: \(r["packageName"] ?? pkg) pid=\(r["pid"] ?? "?") port=\(r["port"] ?? "?") agent=\(r["agentVersion"] ?? "?")")
}

func cmdUiReport(_ c: HelperClient, _ args: Args) throws {
    let pkg = try args.require("package")
    let outDir = args.option("output") ?? "reticle-report"
    let r = try c.call("uiReport", ["package": pkg])
    try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    // The helper already derived the trees device-side; we just persist them.
    for key in ["snapshot", "semantics", "compact"] {
        guard let tree = r[key] else { continue }
        let data = try JSONSerialization.data(withJSONObject: tree, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: "\(outDir)/\(key).json"))
    }
    print("wrote report to \(outDir)")
    print("nodes: \(r["nodeCount"] ?? "?"), compact items: \(r["compactItemCount"] ?? "?"), semantic nodes: \(r["semanticNodeCount"] ?? "?")")
}

func cmdLaunch(_ c: HelperClient, _ args: Args) throws {
    let pkg = try args.require("package")
    let r = try c.call("launch", ["package": pkg])
    print("runtime live: \(r["packageName"] ?? pkg) pid=\(r["pid"] ?? "?") port=\(r["port"] ?? "?") agent=\(r["agentVersion"] ?? "?")")
}

func cmdAct(_ c: HelperClient, _ args: Args) throws {
    guard let gesture = args.positional(1) else { throw HelperError("act needs a gesture (tap/swipe/drag/type)") }
    let pkg = try args.require("package")
    var params: [String: Any] = ["gesture": gesture, "package": pkg]
    // Pass through whatever selector/geometry options were given.
    for k in ["test-id", "resource-id", "ref", "point", "region", "from", "to", "duration", "text"] {
        if let v = args.option(k) { params[selectorKey(k)] = v }
    }
    let r = try c.call("act", params)
    print(r.map { "\($0)=\($1)" }.sorted().joined(separator: " "))
}

func cmdMutate(_ c: HelperClient, _ args: Args) throws {
    let pkg = try args.require("package")
    var params: [String: Any] = [
        "package": pkg,
        "property": try args.require("property"),
        "value": try args.require("value"),
    ]
    for k in ["test-id", "resource-id", "ref", "region"] {
        if let v = args.option(k) { params[selectorKey(k)] = v }
    }
    let r = try c.call("mutate", params)
    print("mutated \(r["ref"] ?? "?") (was \(r["previousValue"] ?? "?"))")
}

func cmdDebug(_ c: HelperClient, _ args: Args) throws {
    switch args.positional(1) {
    case "logs":
        let pkg = try args.require("package")
        let r = try c.call("logs", ["package": pkg])
        let entries = (r["entries"] as? [[String: Any]]) ?? []
        if entries.isEmpty { print("(runtime reachable, but 0 app-authored log entries)") }
        else { for e in entries { print("[\(e["level"] ?? "?")] \(e["message"] ?? "")") } }
    case "logcat":
        let r = try c.call("logcat")
        let lines = (r["lines"] as? [String]) ?? []
        if lines.isEmpty { print("(no 'Reticle' logcat lines — agent likely not linked)") }
        else { lines.forEach { print($0) } }
    default:
        throw HelperError("unknown debug subcommand: \(args.positional(1) ?? "<none>")")
    }
}

func cmdScreenshot(_ c: HelperClient, _ args: Args) throws {
    let out = args.option("output") ?? "screenshot.png"
    var params: [String: Any] = [:]
    if let pkg = args.option("package") { params["package"] = pkg }
    let r = try c.call("screenshot", params)
    guard let b64 = r["pngBase64"] as? String, let data = Data(base64Encoded: b64) else {
        throw HelperError("screenshot returned no image data")
    }
    try data.write(to: URL(fileURLWithPath: out))
    print("wrote \(out) (\(data.count) bytes) via \(r["via"] ?? "?")")
}

/// Render a local snapshot view (tree/compact/node/regions) by delegating to the
/// helper — the derivation stays in Kotlin; the host just prints the text.
func cmdUiRender(_ c: HelperClient, _ args: Args, view: String) throws {
    guard let snapshot = args.positional(2) else { throw HelperError("ui \(view) needs a snapshot.json path") }
    var params: [String: Any] = ["view": view, "snapshot": snapshot]
    if view == "tree", args.option("semantics") != nil { params["view"] = "semantics" }
    if let d = args.option("depth") { params["depth"] = Int(d) ?? 0 }
    for k in ["test-id", "resource-id", "ref"] { if let v = args.option(k) { params[selectorKey(k)] = v } }
    let r = try c.call("render", params)
    print((r["text"] as? String) ?? "")
}

/// Map CLI-style option names to the RPC param keys.
func selectorKey(_ cliName: String) -> String {
    switch cliName {
    case "test-id": return "testId"
    case "resource-id": return "resourceId"
    default: return cliName
    }
}

// --- entry -------------------------------------------------------------------

let argv = Array(CommandLine.arguments.dropFirst())
let args = Args(argv)
let command = args.positional(0)

guard let command else {
    FileHandle.standardError.write(Data("usage: reticle-host <doctor|devices|status|inject|launch|act|mutate|debug|ui> [options]\n".utf8))
    exit(2)
}
guard let launcher = resolveLauncher(args) else {
    FileHandle.standardError.write(Data("could not find the reticle launcher; set RETICLE_LAUNCHER or pass --launcher\n".utf8))
    exit(2)
}

let client = HelperClient(launcher: launcher, javaHome: ProcessInfo.processInfo.environment["JAVA_HOME"])
do {
    try client.start()
    switch command {
    case "doctor":  try cmdDoctor(client)
    case "devices": try cmdDevices(client)
    case "status":  try cmdStatus(client, args)
    case "inject":  try cmdInject(client, args)
    case "launch":  try cmdLaunch(client, args)
    case "act":     try cmdAct(client, args)
    case "mutate":  try cmdMutate(client, args)
    case "debug":   try cmdDebug(client, args)
    case "ui":
        switch args.positional(1) {
        case "report":     try cmdUiReport(client, args)
        case "screenshot": try cmdScreenshot(client, args)
        case "tree":       try cmdUiRender(client, args, view: "tree")
        case "compact":    try cmdUiRender(client, args, view: "compact")
        case "node":       try cmdUiRender(client, args, view: "node")
        case "regions":    try cmdUiRender(client, args, view: "regions")
        default: throw HelperError("unknown ui subcommand: \(args.positional(1) ?? "<none>")")
        }
    default:
        throw HelperError("unknown command: \(command)")
    }
    client.shutdown()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    client.shutdown()
    exit(1)
}
