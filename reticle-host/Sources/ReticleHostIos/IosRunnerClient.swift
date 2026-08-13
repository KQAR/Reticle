import Foundation
import ReticleHostShared
import ReticleProtocol

/// Loopback HTTP client for the system-channel runner.
///
/// Shaped after `IosAgentHTTP` on purpose — same transport, same port-derivation
/// rule, same "the device's loopback reaches us through a USB tunnel" assumption.
/// The only difference is which bundle id feeds the port.
public struct IosRunnerClient: Sendable {
    public let config: IosRunnerConfig
    public let timeout: TimeInterval

    /// Default covers a READ, which is the slow case: every element attribute is a
    /// cross-process query, so a full system-layer walk is tens of seconds. Liveness
    /// probes pass a short timeout explicitly — a slow read must not be confused
    /// with a dead runner, and a dead runner must not take a minute to detect.
    public init(config: IosRunnerConfig, timeout: TimeInterval = 90.0) {
        self.config = config
        self.timeout = timeout
    }

    var port: Int { config.port }

    // MARK: - Endpoints

    public struct Health: Codable, Sendable {
        public var version: String
        public var screenWidth: Double
        public var screenHeight: Double
        public var pointScale: Double
    }

    /// Liveness. Short by design: this is asked in a polling loop.
    public func health() throws -> Health {
        try ReticleJSON.decode(Health.self, from: try get("/health", timeout: 8).data)
    }

    public func overlay() throws -> SystemObservation {
        try ReticleJSON.decode(SystemObservation.self, from: try get("/system/overlay").data)
    }

    public func tree(target: SystemReadTarget) throws -> SystemObservation {
        let query: String
        switch target {
        case .topmostOverlay: query = "topmost"
        case .home: query = "home"
        case .app(let b): query = b
        }
        return try ReticleJSON.decode(
            SystemObservation.self,
            from: try get("/system/tree?target=\(query)").data
        )
    }

    public func tap(label: String) throws -> SystemActionResult {
        try act("/system/tap", ["label": label])
    }

    public func tap(x: Double, y: Double) throws -> SystemActionResult {
        try act("/system/tap", ["x": x, "y": y])
    }

    public func home() throws -> SystemActionResult {
        try act("/system/home", [:])
    }

    public func activate(bundleId: String) throws -> SystemActionResult {
        try act("/system/activate", ["bundleId": bundleId])
    }

    private func act(_ path: String, _ body: [String: Any]) throws -> SystemActionResult {
        let data = try JSONSerialization.data(withJSONObject: body)
        return try ReticleJSON.decode(SystemActionResult.self, from: try post(path, body: data).data)
    }

    public func screenshotPng() throws -> Data {
        try get("/system/screenshot").data
    }

    @discardableResult
    public func shutdown() throws -> Bool {
        _ = try post("/shutdown", body: Data("{}".utf8))
        return true
    }

    // MARK: - Transport

    func get(_ path: String, timeout override: TimeInterval? = nil) throws -> (data: Data, contentType: String) {
        try send(path: path, method: "GET", body: nil, timeout: override ?? timeout)
    }

    func post(_ path: String, body: Data) throws -> (data: Data, contentType: String) {
        try send(path: path, method: "POST", body: body, timeout: timeout)
    }

    private func send(path: String, method: String, body: Data?, timeout: TimeInterval) throws -> (Data, String) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw HelperError("bad system-runner URL for \(config.bundleId)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // Same transport shape as IosAgentHTTP, ResultBox included: a non-2xx from
        // the runner is a refusal WITH a reason in its body, and swallowing that
        // body would throw away the only explanation the caller gets.
        let sema = DispatchSemaphore(value: 0)
        let box = ResultBox<(Data, String)>(
            fallback: .failure(HelperError("no response from the system-channel runner"))
        )
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sema.signal() }
            if let error {
                box.set(.failure(HelperError(
                    "system runner \(method) \(path) failed: \(error.localizedDescription)"
                )))
                return
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let ctype = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            guard let data else {
                box.set(.failure(HelperError("system runner \(method) \(path) returned no body")))
                return
            }
            guard (200..<300).contains(status) else {
                let text = String(decoding: data, as: UTF8.self)
                box.set(.failure(HelperError(
                    "system runner \(method) \(path) -> HTTP \(status): \(text)"
                )))
                return
            }
            box.set(.success((data, ctype)))
        }
        task.resume()
        if sema.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            throw HelperError(
                "system runner \(method) \(path) timed out (is it up on port \(port)?)"
            )
        }
        return try box.value.get()
    }
}

/// Wraps a client with the one-restart-and-retry rule, and makes the restart
/// visible in whatever it returns.
///
/// The restart has to be reported (NFR-011). Relaunching the runner takes the
/// foreground away from whatever was there, which is observable interference with
/// the flow under test — a caller who is not told will blame the app for it. That
/// is the difference between evidence and a lie of omission.
public struct IosRunnerSession: Sendable {
    public let lifecycle: IosRunnerLifecycle
    public let client: IosRunnerClient

    public init(lifecycle: IosRunnerLifecycle) {
        self.lifecycle = lifecycle
        self.client = IosRunnerClient(config: lifecycle.config)
    }

    /// Run `body`; if it fails because the runner is gone, restart once and retry
    /// once. Returns the value plus whether a restart happened.
    public func withRetry<T>(_ body: (IosRunnerClient) async throws -> T) async throws -> (value: T, restarted: Bool) {
        do {
            return (try await body(client), false)
        } catch {
            // Only a vanished process earns a retry. Any other error is the
            // runner's considered answer and must not be papered over by a restart.
            guard await !lifecycle.isRunning() else { throw error }
            await try lifecycle.ensureConnected()
            // A second failure is final: retrying forever would turn a real problem
            // into a process that looks busy while repeatedly disrupting the device.
            return (try await body(client), true)
        }
    }

    /// The same rule for an observation, stamping the restart onto the result so it
    /// travels with the evidence rather than only appearing in a log line.
    public func observe(_ body: @escaping (IosRunnerClient) async throws -> SystemObservation) async throws -> SystemObservation {
        let (value, restarted) = try await withRetry(body)
        guard restarted else { return value }
        var stamped = value
        stamped.runnerRestarted = true
        return stamped
    }
}
