import Foundation

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
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success(r)
        return
    }
    print("mutated \(r["ref"] ?? "?") (was \(r["previousValue"] ?? "?"))")
}

func cmdDebug(_ c: HelperClient, _ args: Args) throws {
    switch args.positional(1) {
    case "logs":
        let pkg = try args.require("package")
        let r = try c.call("logs", ["package": pkg])
        let entries = (r["entries"] as? [[String: Any]]) ?? []
        if JsonEnvelope.enabled(args) {
            try JsonEnvelope.success(["entries": entries])
            return
        }
        if entries.isEmpty {
            print("(runtime reachable, but 0 app-authored log entries)")
        } else {
            for e in entries { print("[\(e["level"] ?? "?")] \(e["message"] ?? "")") }
        }
    case "logcat":
        let r = try c.call("logcat")
        let lines = (r["lines"] as? [String]) ?? []
        if JsonEnvelope.enabled(args) {
            try JsonEnvelope.success(["lines": lines])
            return
        }
        if lines.isEmpty {
            print("(no 'Reticle' logcat lines — agent likely not linked)")
        } else {
            lines.forEach { print($0) }
        }
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
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success([
            "output": out,
            "bytes": data.count,
            "via": r["via"] ?? NSNull(),
        ])
        return
    }
    print("wrote \(out) (\(data.count) bytes) via \(r["via"] ?? "?")")
}

func cmdUiRender(_ c: HelperClient, _ args: Args, view: String) throws {
    var params: [String: Any] = ["view": view]
    let live = args.option("live") != nil
    if live {
        params["live"] = "true"
        params["package"] = try args.require("package")
    } else {
        guard let snapshot = args.positional(2) else {
            throw HelperError("ui \(view) needs a snapshot.json path (or --live --package <pkg>)")
        }
        params["snapshot"] = snapshot
        if let pkg = args.option("package") { params["package"] = pkg }
    }
    if view == "tree", args.option("semantics") != nil { params["view"] = "semantics" }
    if let d = args.option("depth") { params["depth"] = Int(d) ?? 0 }
    for k in ["test-id", "resource-id", "css", "ref"] {
        if let v = args.option(k) { params[selectorKey(k)] = v }
    }
    let r = try c.call("render", params)
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success(["text": (r["text"] as? String) ?? ""])
        return
    }
    print((r["text"] as? String) ?? "")
}

func selectorKey(_ cliName: String) -> String {
    switch cliName {
    case "test-id": return "testId"
    case "resource-id": return "resourceId"
    default: return cliName
    }
}
