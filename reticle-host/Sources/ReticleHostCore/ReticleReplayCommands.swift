import Foundation

/// `reticle replay` — two flavors:
/// - `gif <trace-dir>` stitches an `act --trace-output` flow into a device-framed
///   animated GIF. Host-local: reads evidence on disk, never touches a device.
/// - `flow <request-id>` re-sends a captured network flow through Loom's engine
///   with overrides and emits the diff vs the original (needs `reticle serve`).
func cmdReplay(_ args: Args) throws {
    switch args.positional(1) {
    case "gif":
        try cmdReplayGif(args)
    case "flow":
        try cmdReplayFlow(args)
    default:
        throw HelperError("unknown replay subcommand: \(args.positional(1) ?? "<none>") (expected: gif, flow)")
    }
}

private func cmdReplayFlow(_ args: Args) throws {
    guard let requestId = args.positional(2) ?? args.option("request-id") else {
        throw HelperError("usage: reticle replay flow <request-id> [--method M] [--url U] [--set-headers '{\"k\":\"v\"}'] [--remove-headers '[\"k\"]'] [--body TEXT | --body-file PATH | --clear-body]")
    }
    let request = NetworkReplayRequest(
        method: args.option("method"),
        url: args.option("url"),
        setHeaders: try jsonObjectOption(args.option("set-headers"), name: "--set-headers"),
        removeHeaders: try jsonArrayOption(args.option("remove-headers"), name: "--remove-headers"),
        body: args.option("body"),
        bodyBase64: try args.option("body-file").map { try Data(contentsOf: URL(fileURLWithPath: $0)).base64EncodedString() },
        clearBody: args.option("clear-body") == "true" ? true : nil
    )
    let result = try DaemonFlowClient().replay(requestId: requestId, request: request)
    printReplayResult(result)
}

private func printReplayResult(_ result: NetworkReplayResult) {
    print("replay flow: \(result.requestId) (from \(result.replayedFrom))")
    if let error = result.error {
        print("  error: \(error)")
    }
    let d = result.diff
    let statusMark = d.statusChanged ? "changed" : "same"
    print("  status: \(d.statusFrom.map(String.init) ?? "-") -> \(d.statusTo.map(String.init) ?? "-") [\(statusMark)]")
    let bodyMark = d.bodyChanged ? "changed" : "same"
    print("  body: \(d.bodyBytesFrom) -> \(d.bodyBytesTo) bytes [\(bodyMark)]")
    if !d.headersAdded.isEmpty || !d.headersRemoved.isEmpty || !d.headersChanged.isEmpty {
        var parts: [String] = []
        if !d.headersAdded.isEmpty { parts.append("+[\(d.headersAdded.joined(separator: ","))]") }
        if !d.headersRemoved.isEmpty { parts.append("-[\(d.headersRemoved.joined(separator: ","))]") }
        if !d.headersChanged.isEmpty { parts.append("~[\(d.headersChanged.joined(separator: ","))]") }
        print("  headers: \(parts.joined(separator: " "))")
    }
    print("  identical: \(d.isIdentical)")
}

private func jsonObjectOption(_ raw: String?, name: String) throws -> [String: String]? {
    guard let raw, let data = raw.data(using: .utf8) else { return nil }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw HelperError("\(name) must be a JSON object")
    }
    return object.mapValues { "\($0)" }
}

private func jsonArrayOption(_ raw: String?, name: String) throws -> [String]? {
    guard let raw, let data = raw.data(using: .utf8) else { return nil }
    guard let array = try JSONSerialization.jsonObject(with: data) as? [Any] else {
        throw HelperError("\(name) must be a JSON array of strings")
    }
    return array.map { "\($0)" }
}

private final class DaemonFlowClient {
    private let baseURL: URL
    private let timeout: TimeInterval

    init(discovery: DaemonDiscovery = DaemonDiscovery(), timeout: TimeInterval = 40.0) throws {
        guard let info = discovery.readLive() else {
            throw HelperError("reticle serve is not running; start it before using reticle replay flow")
        }
        guard let baseURL = URL(string: "http://127.0.0.1:\(info.port)/sessions/current/") else {
            throw HelperError("invalid daemon URL")
        }
        self.baseURL = baseURL
        self.timeout = timeout
    }

    func replay(requestId: String, request: NetworkReplayRequest) throws -> NetworkReplayResult {
        let encoded = requestId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? requestId
        guard let url = URL(string: "flows/\(encoded)/replay", relativeTo: baseURL)?.absoluteURL else {
            throw HelperError("invalid daemon replay path for \(requestId)")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<Data>(fallback: .failure(HelperError("daemon replay API returned no result")))
        let task = URLSession.shared.dataTask(with: urlRequest) { data, rawResponse, error in
            defer { semaphore.signal() }
            if let error { box.set(.failure(error)); return }
            let status = (rawResponse as? HTTPURLResponse)?.statusCode ?? 0
            let data = data ?? Data()
            guard (200..<300).contains(status) else {
                let message = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                box.set(.failure(HelperError("daemon replay API failed with HTTP \(status): \(message)")))
                return
            }
            box.set(.success(data))
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw HelperError("daemon replay API timed out")
        }
        return try JSONDecoder().decode(NetworkReplayResult.self, from: try box.value.get())
    }
}

private func cmdReplayGif(_ args: Args) throws {
    guard let tracePath = args.positional(2) ?? args.option("trace") else {
        throw HelperError("usage: reticle replay gif <trace-dir> [--output <file.gif>] [--width <px>] [--frame-ms <ms>]")
    }
    let root = URL(fileURLWithPath: tracePath)
    let steps = try ReplayTraceDiscovery.steps(at: root)

    var options = ReplayRenderer.Options()
    if let width = args.option("width") {
        guard let value = Int(width), value >= 80 else {
            throw HelperError("--width must be an integer ≥ 80")
        }
        options.screenWidth = value
    }
    if let frameMs = args.option("frame-ms") {
        guard let value = Int(frameMs), value >= 100 else {
            throw HelperError("--frame-ms must be an integer ≥ 100")
        }
        options.frameMs = value
    }

    let output = args.option("output").map { URL(fileURLWithPath: $0) }
        ?? root.appendingPathComponent("replay.gif")
    let result = try ReplayRenderer.renderGIF(steps: steps, to: output, options: options)

    for actionId in result.skippedSteps {
        FileHandle.standardError.write(Data("replay: skipped \(actionId) (no screenshots)\n".utf8))
    }
    print("replay gif: \(result.outputURL.path) steps=\(result.stepCount) frames=\(result.frameCount) size=\(result.canvasWidth)x\(result.canvasHeight)")
}
