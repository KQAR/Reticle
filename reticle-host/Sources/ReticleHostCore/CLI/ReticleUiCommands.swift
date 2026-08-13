import Foundation

func cmdMutate(_ backend: HostBackend, _ args: Args) async throws {
    let pkg = try args.require("package")
    let result = try await backend.mutate(MutateRequest(
        package: pkg,
        property: try args.require("property"),
        value: try args.require("value"),
        selector: args.hostSelector(["test-id", "resource-id", "ref", "region"])
    ))
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success(result.jsonObject)
        return
    }
    print("mutated \(result.ref ?? "?") (was \(result.previousValue ?? "?"))")
}

func cmdDebug(_ backend: HostBackend, _ args: Args) async throws {
    switch args.positional(1) {
    case "logs":
        let entries = try await backend.logs(PackageRequest(package: try args.require("package")))
        if JsonEnvelope.enabled(args) {
            try JsonEnvelope.success(["entries": entries.map(\.jsonObject)])
            return
        }
        if entries.isEmpty {
            print("(runtime reachable, but 0 app-authored log entries)")
        } else {
            for e in entries { print("[\(e.level)] \(e.message)") }
        }
    case "logcat":
        let lines = try await backend.logcat()
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

func cmdScreenshot(_ backend: HostBackend, _ args: Args) async throws {
    let out = args.option("output") ?? "screenshot.png"
    let result = try await backend.screenshot(ScreenshotRequest(package: args.option("package")))
    guard let data = Data(base64Encoded: result.pngBase64) else {
        throw HelperError("screenshot returned no image data")
    }
    try data.write(to: URL(fileURLWithPath: out))
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success([
            "output": out,
            "bytes": data.count,
            "via": result.via ?? NSNull(),
            "degraded": result.degraded,
        ])
        return
    }
    print("wrote \(out) (\(data.count) bytes) via \(result.via ?? "?")")
    // An absence must be labelled, not inferred: a blank rect in the image is
    // otherwise indistinguishable from the app having drawn nothing there.
    for line in result.degraded { print("degraded: \(line)") }
}

func cmdUiRender(_ backend: HostBackend, _ args: Args, view: String) async throws {
    var view = view
    var snapshotPath: String
    var package = args.option("package")
    // `--package <pkg>` with no path means the live tree. There is nothing else it
    // could mean — a package name is not a snapshot path — and every other command
    // (`ui report`, `act *`, `status`) already takes `--package` on its own, so
    // demanding `--live` here bought nothing but a failed first command per session.
    // An explicit path still wins over `--package`, which stays required for live.
    if let positional = args.positional(2) {
        snapshotPath = positional
    } else if args.option("live") != nil || package != nil {
        snapshotPath = RenderRequest.liveSnapshotPath
        package = try args.require("package")
    } else {
        throw HelperError("ui \(view) needs a snapshot.json path (or --package <pkg> for the live tree)")
    }
    if view == "tree", args.option("semantics") != nil { view = "semantics" }
    let result = try await backend.render(RenderRequest(
        view: view,
        snapshotPath: snapshotPath,
        depth: try args.intOption("depth"),
        selector: args.hostSelector(["test-id", "resource-id", "css", "ref"]),
        package: package,
        // `--window top` (or a ref): a stacked screen puts two live windows in one
        // capture, and the flat views interleave them. Scoping is applied to the
        // snapshot, so every view and the `@N` numbering narrow together.
        window: args.option("window")
    ))
    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success(["text": result.text])
        return
    }
    print(result.text)
}

extension Args {
    /// Reads the given CLI flags into a `HostSelector`.
    ///
    /// The flag-name → protocol-field mapping used to be a `selectorKey(_:)` string
    /// function applied to a dictionary, so a command could quietly send `resource-id`
    /// (never a wire key) and get a selector miss on a device instead of an error on a
    /// laptop. Now the fields are named once, here.
    func hostSelector(_ flags: [String]) -> HostSelector {
        var selector = HostSelector()
        for flag in flags {
            guard let value = option(flag) else { continue }
            switch flag {
            case "test-id": selector.testId = value
            case "resource-id": selector.resourceId = value
            case "css": selector.cssSelector = value
            case "ref": selector.ref = value
            case "point": selector.point = value
            case "label": selector.label = value
            case "region": selector.region = value
            case "alias": selector.alias = value
            default: continue
            }
        }
        return selector
    }
}
