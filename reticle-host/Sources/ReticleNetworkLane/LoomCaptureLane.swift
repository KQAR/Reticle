import Foundation
import ReticleHostShared
// Loom's SPM library products `LoomProxyCore` / `LoomSharedModels` expose the
// modules under their target names (`ProxyCore` / `SharedModels`) — that's what
// `import` resolves. No collision with Reticle's own module names.
import ProxyCore
import SharedModels

/// Capture lane backed by Loom's `ProxyEngine`, an alternative to the in-tree
/// `NetworkProxyServer`. It runs the engine, subscribes to its flow stream, and
/// republishes each exchange as the same `network.*` events the built-in proxy
/// emits — so the Web panel, SSE stream, and agent see an identical envelope.
///
/// The division of labor is the point: transport (SwiftNIO proxy, HTTPS MITM,
/// on-demand CA) is Loom's; normalization, header redaction, body-as-artifact
/// persistence, and the session event stream stay here. Flows are not persisted
/// by Loom (`persistFlows: false`) — Reticle owns storage via `events.jsonl` and
/// `network-bodies/`.
///
/// Scope (milestone 1): capture only. Traffic rules / mocks are not yet synced
/// into the engine, and Loom's engine currently binds loopback only, so
/// non-loopback (real-device Wi-Fi) capture still needs the built-in proxy.
public final class LoomCaptureLane: @unchecked Sendable {
    private let store: any NetworkEventSink
    private let configuration: NetworkProxyConfiguration
    private let engine: ProxyEngine
    private let bodyStore: NetworkBodyStore
    private let factory: NetworkEventFactory

    private let lock = NSLock()
    private var seen = Set<UUID>()
    private var streamTask: Task<Void, Never>?
    private var startBound: Int?
    private var startError: Error?

    public private(set) var port: Int

    /// Creates a Loom-backed capture lane owned by the supplied session store.
    public init(store: any NetworkEventSink, configuration: NetworkProxyConfiguration) {
        self.store = store
        self.configuration = configuration
        self.engine = ProxyEngine(persistFlows: false)
        self.bodyStore = NetworkBodyStore(
            sessionDirectory: store.sessionDirectory,
            limitBytes: configuration.bodyLimitBytes
        )
        self.factory = NetworkEventFactory(target: configuration.target)
        self.port = configuration.port
    }

    /// Starts the engine (bridging its async API to the synchronous lifecycle the
    /// daemon expects) and begins republishing flows. When MITM is enabled the
    /// CA is exported to `caDirectory` so the existing device-trust flow can
    /// install it.
    public func start() throws {
        let engine = self.engine
        let requestedPort = configuration.port
        let mitm = configuration.mitmEnabled
        let hosts = configuration.tlsHostAllowlist
        let caDirectory = configuration.caDirectory
        let ready = DispatchSemaphore(value: 0)

        Task { [weak self] in
            do {
                if mitm {
                    await engine.setSSLScope(SSLScope(enabled: true, include: hosts))
                }
                let bound = try await engine.start(port: requestedPort)
                if let caDirectory, let der = await engine.caCertificateDER() {
                    try? LoomCaptureLane.writeCA(der: der, to: caDirectory)
                }
                self?.lock.withLock { self?.startBound = bound }
            } catch {
                self?.lock.withLock { self?.startError = error }
            }
            ready.signal()
        }

        switch ready.wait(timeout: .now() + 30) {
        case .success:
            break
        case .timedOut:
            throw NetworkProxyError.startTimedOut
        }
        let (bound, error) = lock.withLock { (startBound, startError) }
        if let error { throw error }
        if let bound { port = bound }
        subscribe(engine: engine)
    }

    /// Stops the engine and the flow subscription.
    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        let engine = self.engine
        let done = DispatchSemaphore(value: 0)
        Task {
            await engine.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
    }

    private func subscribe(engine: ProxyEngine) {
        streamTask = Task { [weak self] in
            let stream = await engine.flowStream()
            for await flow in stream {
                if Task.isCancelled { break }
                self?.handle(flow)
            }
        }
    }

    /// Translates one Loom `Flow` update into the network event stream: a
    /// `network.request` on first sighting, then `network.response`/`network.error`
    /// once the exchange completes. Loom yields the same flow id twice (start, then
    /// completion), which maps cleanly onto the two events.
    private func handle(_ flow: Flow) {
        let requestId = flow.id.uuidString
        let firstSeen = lock.withLock { seen.insert(flow.id).inserted }

        if firstSeen {
            var payload = makePayload(flow)
            var refs: [String: String] = [:]
            if let body = flow.request.body,
               let stored = try? bodyStore.store(body, requestId: requestId, role: "request") {
                refs[stored.refName] = stored.path
                payload.requestBodyBytes = stored.bytes
                payload.requestBodyTruncated = stored.truncated
            }
            store.emit(factory.event(.request, payload: payload, refs: refs))
        }

        guard flow.completedAt != nil else { return }

        var payload = makePayload(flow)
        var refs: [String: String] = [:]
        if let body = flow.response?.body,
           let stored = try? bodyStore.store(body, requestId: requestId, role: "response") {
            refs[stored.refName] = stored.path
            payload.responseBodyBytes = stored.bytes
            payload.responseBodyTruncated = stored.truncated
        }
        let type: NetworkEventType = flow.error == nil ? .response : .error
        store.emit(factory.event(type, payload: payload, refs: refs))
    }

    private func makePayload(_ flow: Flow) -> NetworkEventPayload {
        let components = URLComponents(string: flow.request.url)
        let scheme = (components?.scheme ?? "http").lowercased()
        let host = components?.host ?? ""
        let port = components?.port ?? (scheme == "https" ? 443 : 80)
        let path = (components?.path).flatMap { $0.isEmpty ? nil : $0 } ?? "/"

        var payload = NetworkEventPayload(
            requestId: flow.id.uuidString,
            scheme: scheme,
            method: flow.request.method,
            url: flow.request.url,
            host: host,
            port: port,
            path: path,
            startMillis: Self.millis(flow.startedAt),
            // Loom only emits a flow for traffic it actually observed (plain HTTP,
            // or HTTPS it decrypted) — blind CONNECT tunnels never surface, so
            // there is no `tunnel` event and an https flow implies MITM.
            tunnel: false,
            mitm: scheme == "https"
        )
        payload.requestHeaders = NetworkHeaders.redacted(
            pairs: flow.request.headers.map { (name: $0.name, value: $0.value) }
        )
        if let completedAt = flow.completedAt {
            payload.endMillis = Self.millis(completedAt)
        }
        if let response = flow.response {
            payload.status = response.statusCode
            payload.responseHeaders = NetworkHeaders.redacted(
                pairs: response.headers.map { (name: $0.name, value: $0.value) }
            )
        }
        if let error = flow.error {
            payload.error = error
        }
        return payload
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Writes the engine's root CA (DER) into the proxy CA directory as
    /// `reticle-ca.cer`, matching where the device-trust flow looks for it.
    private static func writeCA(der: Data, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try der.write(to: directory.appendingPathComponent("reticle-ca.cer"), options: .atomic)
    }
}
