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
/// persistence, mock rules, and the session event stream stay here. Flows are
/// not persisted by Loom (`persistFlows: false`) — Reticle owns storage via
/// `events.jsonl` and `network-bodies/`.
///
/// Differences from the built-in proxy: Loom only emits a flow for traffic it
/// observed (plain HTTP or decrypted HTTPS), so there is no blind-tunnel
/// (`tunnel: true`) event; and Loom currently binds loopback only, so
/// non-loopback (real-device Wi-Fi) capture still needs the built-in proxy.
public final class LoomCaptureLane: @unchecked Sendable {
    private let store: any NetworkEventSink
    private let configuration: NetworkProxyConfiguration
    private let mockStore: NetworkMockStore?
    private let engine: ProxyEngine
    private let bodyStore: NetworkBodyStore
    private let factory: NetworkEventFactory

    private let lock = NSLock()
    private var seen = Set<UUID>()
    private var streamTask: Task<Void, Never>?
    private var startBound: Int?
    private var startError: Error?
    /// Serializes full-rule-set syncs so two overlapping mock mutations can't
    /// interleave a delete-all with an add-all.
    private let syncQueue = DispatchQueue(label: "dev.reticle.loom.mock-sync")

    public private(set) var port: Int

    /// Creates a Loom-backed capture lane owned by the supplied session store.
    /// When a mock store is supplied its rules are translated into the engine and
    /// kept in sync (call `syncMocks()` after any mutation).
    public init(
        store: any NetworkEventSink,
        configuration: NetworkProxyConfiguration,
        mockStore: NetworkMockStore? = nil
    ) {
        self.store = store
        self.configuration = configuration
        self.mockStore = mockStore
        self.engine = ProxyEngine(persistFlows: false)
        self.bodyStore = NetworkBodyStore(
            sessionDirectory: store.sessionDirectory,
            limitBytes: configuration.bodyLimitBytes
        )
        self.factory = NetworkEventFactory(target: configuration.target)
        self.port = configuration.port
    }

    /// Starts the engine (bridging its async API to the synchronous lifecycle the
    /// daemon expects), exports the CA when MITM is enabled, seeds the mock rules,
    /// and begins republishing flows.
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
                if let caDirectory {
                    await LoomCaptureLane.exportCA(engine: engine, to: caDirectory)
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
        syncMocks()
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

    /// Re-translates the whole mock rule set into the engine (full replace). Safe
    /// to call after any mock mutation; a no-op when no mock store is attached.
    public func syncMocks() {
        guard let mockStore else { return }
        let engine = self.engine
        // Snapshot + apply on the sync queue so a mutation callback fired while the
        // mock store still holds its lock only enqueues here (exportPackage, which
        // re-takes that lock, then runs off it).
        syncQueue.async {
            let translated = LoomCaptureLane.translate(try? mockStore.exportPackage())
            let done = DispatchSemaphore(value: 0)
            Task {
                let current = await engine.rulesState().rules
                for rule in current { try? await engine.deleteRule(id: rule.id) }
                for rule in translated { try? await engine.addRule(rule) }
                done.signal()
            }
            done.wait()
        }
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
        // A mock/rule that acted is recorded on the flow as the rule name, which we
        // set to the Reticle mock-rule id (see `translate`), so evidence carries
        // `mockRuleId` just like the built-in proxy.
        if let applied = flow.appliedRules?.first {
            payload.mocked = true
            payload.mockRuleId = applied.name
        }
        return payload
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Writes the engine's root CA to the proxy CA directory in both the DER
    /// (`reticle-ca.cer`) and PEM (`reticle-ca.pem`) forms the device-trust flow
    /// and `curl --cacert` expect.
    private static func exportCA(engine: ProxyEngine, to directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let der = await engine.caCertificateDER() {
            try? der.write(to: directory.appendingPathComponent("reticle-ca.cer"), options: .atomic)
        }
        if let pemURL = try? await engine.exportCACertificate(),
           let pem = try? Data(contentsOf: pemURL) {
            try? pem.write(to: directory.appendingPathComponent("reticle-ca.pem"), options: .atomic)
        }
    }

    // MARK: - Mock translation

    /// Translates Reticle's mock rules + values into Loom `TrafficRule`s. The Loom
    /// rule name carries the Reticle rule id so an applied mock is attributable
    /// back on the captured flow. Rules are ordered by descending priority to
    /// match Reticle's precedence (Loom applies the first matching mock).
    private static func translate(_ export: NetworkMockExport?) -> [TrafficRule] {
        guard let export else { return [] }
        let valuesById = Dictionary(export.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return export.rules
            .sorted { $0.priority > $1.priority }
            .compactMap { rule in
                guard let value = valuesById[rule.valueId] else { return nil }
                let mock = MockResponseAction(
                    statusCode: value.status,
                    headers: value.headers.map { HeaderPair(name: $0.key, value: $0.value) },
                    bodyBase64: value.bodyBase64,
                    contentType: value.contentType
                )
                return TrafficRule(
                    name: rule.id,
                    isEnabled: rule.enabled,
                    match: translateMatch(rule),
                    actions: RuleActions(route: .mock(mock))
                )
            }
    }

    private static func translateMatch(_ rule: NetworkMockRule) -> RuleMatch {
        let methods = rule.method == "ANY" ? [] : [rule.method]
        let host = rule.host
        let query = rule.query
        // Reticle matches a `/`-leading pattern against the URL path; Loom matches
        // the full URL, so a path pattern is lifted to a regex that skips the
        // scheme+authority prefix.
        let isPath = rule.url.hasPrefix("/")
        let originPrefix = "^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+"

        switch rule.match {
        case .regex:
            let pattern = isPath ? originPrefix + stripLeadingCaret(rule.url) : rule.url
            return RuleMatch(urlPattern: pattern, isRegex: true, methods: methods, hostPattern: host, query: query)
        case .exact:
            if isPath {
                let pattern = originPrefix + NSRegularExpression.escapedPattern(for: rule.url) + "(\\?.*)?$"
                return RuleMatch(urlPattern: pattern, isRegex: true, methods: methods, hostPattern: host, query: query)
            }
            return RuleMatch(urlPattern: rule.url, methods: methods, isExact: true, hostPattern: host, query: query)
        case .prefix:
            if isPath {
                let pattern = originPrefix + NSRegularExpression.escapedPattern(for: rule.url)
                return RuleMatch(urlPattern: pattern, isRegex: true, methods: methods, hostPattern: host, query: query)
            }
            // Loom's non-regex, non-exact pattern is a prefix match by default.
            return RuleMatch(urlPattern: rule.url, methods: methods, hostPattern: host, query: query)
        }
    }

    private static func stripLeadingCaret(_ pattern: String) -> String {
        pattern.hasPrefix("^") ? String(pattern.dropFirst()) : pattern
    }
}
