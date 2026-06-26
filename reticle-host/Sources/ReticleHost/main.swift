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

// --- entry -------------------------------------------------------------------

let argv = Array(CommandLine.arguments.dropFirst())
let args = Args(argv)
let command = args.positional(0)

guard let command else {
    FileHandle.standardError.write(Data("usage: reticle-host <doctor|devices|status|inject|ui> [options]\n".utf8))
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
    case "ui":
        guard args.positional(1) == "report" else { throw HelperError("unknown ui subcommand: \(args.positional(1) ?? "<none>")") }
        try cmdUiReport(client, args)
    default:
        throw HelperError("unknown command: \(command)")
    }
    client.shutdown()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    client.shutdown()
    exit(1)
}
