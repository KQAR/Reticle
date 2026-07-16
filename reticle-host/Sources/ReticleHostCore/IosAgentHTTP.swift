import Foundation
import ReticleProtocol

/// Direct loopback HTTP to the in-process iOS agent — the Swift analogue of the
/// Kotlin `RuntimeClient`, minus the port-forward step: an iOS simulator shares
/// the host's loopback, so the host reaches `127.0.0.1:<derivedPort>` directly.
/// The port is derived from the bundle id with the same `PortMap` the agent uses.
struct IosAgentHTTP {
    let bundleId: String
    let timeout: TimeInterval

    init(bundleId: String, timeout: TimeInterval = 15.0) {
        self.bundleId = bundleId
        self.timeout = timeout
    }

    var port: Int { PortMap.derivePort(bundleId) }

    private func url(_ path: String) throws -> URL {
        guard let u = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw HelperError("bad agent URL for \(bundleId)")
        }
        return u
    }

    /// GET the endpoint and return the raw body bytes (plus content type).
    @discardableResult
    func get(_ path: String) throws -> (data: Data, contentType: String) {
        try send(path: path, method: "GET", body: nil)
    }

    @discardableResult
    func post(_ path: String, body: Data) throws -> (data: Data, contentType: String) {
        try send(path: path, method: "POST", body: body)
    }

    private func send(path: String, method: String, body: Data?) throws -> (Data, String) {
        var request = URLRequest(url: try url(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpBody = body

        let sema = DispatchSemaphore(value: 0)
        let box = ResultBox<(Data, String)>(fallback: .failure(HelperError("no response from agent")))
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sema.signal() }
            if let error {
                box.set(.failure(HelperError("agent \(method) \(path) failed: \(error.localizedDescription)")))
                return
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let ctype = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            guard let data else {
                box.set(.failure(HelperError("agent \(method) \(path) returned no body")))
                return
            }
            guard (200..<300).contains(status) else {
                let text = String(decoding: data, as: UTF8.self)
                box.set(.failure(HelperError("agent \(method) \(path) -> HTTP \(status): \(text)")))
                return
            }
            box.set(.success((data, ctype)))
        }
        task.resume()
        if sema.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            throw HelperError("agent \(method) \(path) timed out (is the runtime up on port \(port)?)")
        }
        return try box.value.get()
    }

    /// GET and decode JSON into a top-level `[String: Any]`.
    func getJSONObject(_ path: String) throws -> [String: Any] {
        let (data, _) = try get(path)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HelperError("agent \(path) did not return a JSON object")
        }
        return obj
    }

    /// Probe `/runtime`; returns the parsed RuntimeInfo or nil if unreachable.
    func probeRuntime() -> RuntimeInfo? {
        guard let (data, _) = try? get(Endpoints.runtime) else { return nil }
        return try? ReticleJSON.decode(RuntimeInfo.self, from: data)
    }

    /// Poll `/runtime` until healthy or timeout.
    @discardableResult
    func waitForRuntime(deadline: TimeInterval = 10.0) -> RuntimeInfo? {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if let info = probeRuntime() { return info }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return nil
    }
}
