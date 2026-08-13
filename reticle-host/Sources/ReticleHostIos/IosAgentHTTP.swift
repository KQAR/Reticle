import Foundation
import ReticleHostShared
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
    func get(_ path: String) async throws -> (data: Data, contentType: String) {
        try await send(path: path, method: "GET", body: nil)
    }

    @discardableResult
    func post(_ path: String, body: Data) async throws -> (data: Data, contentType: String) {
        try await send(path: path, method: "POST", body: body)
    }

    /// `URLSession`'s async form. This used to be the callback form bridged back to
    /// a blocking caller with a semaphore, a `ResultBox` and a second timeout on top
    /// of `URLRequest`'s own — three moving parts to express one round trip, and a
    /// call that could not be cancelled once started.
    private func send(path: String, method: String, body: Data?) async throws -> (Data, String) {
        var request = URLRequest(url: try url(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw HelperError("agent \(method) \(path) timed out (is the runtime up on port \(port)?)")
        } catch {
            throw HelperError("agent \(method) \(path) failed: \(error.localizedDescription)")
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let ctype = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        guard (200..<300).contains(status) else {
            let text = String(decoding: data, as: UTF8.self)
            throw HelperError("agent \(method) \(path) -> HTTP \(status): \(text)")
        }
        return (data, ctype)
    }

    /// GET and decode JSON into a top-level `[String: Any]`.
    func getJSONObject(_ path: String) async throws -> [String: Any] {
        let (data, _) = try await get(path)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HelperError("agent \(path) did not return a JSON object")
        }
        return obj
    }

    /// Probe `/runtime`; returns the parsed RuntimeInfo or nil if unreachable.
    func probeRuntime() async -> RuntimeInfo? {
        guard let (data, _) = try? await get(Endpoints.runtime) else { return nil }
        return try? ReticleJSON.decode(RuntimeInfo.self, from: data)
    }

    /// Poll `/runtime` until healthy or timeout.
    ///
    /// `Task.sleep` rather than `Thread.sleep`: this is the longest wait in a cold
    /// launch, and it is now a cancellation point — a Ctrl-C during it stops the
    /// command instead of finishing the poll first.
    @discardableResult
    func waitForRuntime(deadline: TimeInterval = 10.0) async -> RuntimeInfo? {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if let info = await probeRuntime() { return info }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return nil }
        }
        return nil
    }
}
