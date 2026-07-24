import Foundation
import ReticleHostShared
// Loom's SPM library products `LoomProxyCore` / `LoomSharedModels` expose the
// modules under their target names (`ProxyCore` / `SharedModels`) — that's what
// `import` resolves. No collision with Reticle's own module names.
import ProxyCore
import SharedModels

/// The host capture lane, backed by Loom's `ProxyEngine`. It runs the engine,
/// subscribes to its flow stream, and republishes each exchange as `network.*`
/// events into the session store — the envelope the Web panel, SSE stream, and
/// agent consume.
///
/// The division of labor is the point: transport (SwiftNIO proxy, HTTPS MITM,
/// on-demand CA) is Loom's; normalization, header redaction, body-as-artifact
/// persistence, mock rules, and the session event stream stay here. Flows are
/// not persisted by Loom (`persistFlows: false`) — Reticle owns storage via
/// `events.jsonl` and `network-bodies/`.
///
/// Parity with the built-in proxy: decrypted HTTPS and plain HTTP arrive as
/// normal flows, and un-decrypted CONNECTs surface as `tunnel: true` events
/// (Loom's `observeTunnels` is enabled here). The engine honors
/// `configuration.bindHost`, so non-loopback (real-device Wi-Fi) capture works too.
/// Reticle-local view of Loom's phone-onboarding info, so the daemon layer never
/// imports Loom's modules to read it.
public struct PhoneOnboarding: Sendable {
    /// Provisioning landing-page URL (also encoded in the QR) to open on the device.
    public let url: String
    /// `host:port` the device should point its proxy at.
    public let proxyAddress: String
    /// CA SHA-256 fingerprint, to confirm the installed profile.
    public let fingerprint: String
    /// PNG bytes of the QR encoding `url`.
    public let qrPNG: Data
}

/// One-shot holder to carry an async result out of a bridging `Task` under the
/// Swift 6 concurrency checker (a captured `var` isn't allowed).
private final class OnboardingBox: @unchecked Sendable {
    var value: Result<PhoneOnboardingInfo, Error>?
}

/// One-shot holders to carry an async flow/replay result out of a bridging `Task`.
private final class FlowBox: @unchecked Sendable {
    var flow: Flow?
}
private final class ReplayResultBox: @unchecked Sendable {
    var result: Result<Flow, Error>?
}
private final class ErrorBox: @unchecked Sendable {
    var error: Error?
}

public final class LoomCaptureLane: @unchecked Sendable, FlowReplaying {
    private let store: any NetworkEventSink
    private let configuration: NetworkProxyConfiguration
    private let ruleStore: NetworkRuleStore?
    private let engine: ProxyEngine
    private let bodyStore: NetworkBodyStore
    private let factory: NetworkEventFactory

    private let lock = NSLock()
    /// Flow ids whose `network.request` event has been emitted, so the completion
    /// pass emits only `network.response`/`network.error`. Bounded FIFO — a
    /// long-lived daemon would otherwise grow this set without limit. Evicting the
    /// oldest id at worst re-emits a `network.request` for a flow that completes
    /// much later; that's a rare cosmetic duplicate, not lost evidence.
    private var seen = Set<UUID>()
    private var seenOrder: [UUID] = []
    private let seenCapacity = 8192
    private var streamTask: Task<Void, Never>?
    private var startBound: Int?
    private var startError: Error?
    /// Set (under `lock`) when a bridged async start is abandoned by the sync side on
    /// timeout. The bridging Task reads it after the engine call returns: if the sync
    /// side gave up, the Task stops the now-orphaned engine/server rather than leaking
    /// a bound port. Merely cancelling the Task wouldn't help — Loom's actor calls
    /// don't check cancellation, so a start already in flight still binds.
    private var startAbandoned = false
    private var onboardingAbandoned = false
    /// Serializes full-rule-set syncs so two overlapping rule mutations can't
    /// interleave a delete-all with an add-all.
    private let syncQueue = DispatchQueue(label: "dev.reticle.loom.rule-sync")

    public private(set) var port: Int

    /// Creates a Loom-backed capture lane owned by the supplied session store.
    /// When a rule store is supplied its rules are translated into the engine and
    /// kept in sync (call `syncRules()` after any mutation).
    public init(
        store: any NetworkEventSink,
        configuration: NetworkProxyConfiguration,
        ruleStore: NetworkRuleStore? = nil
    ) {
        self.store = store
        self.configuration = configuration
        self.ruleStore = ruleStore
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
        let bindHost = configuration.bindHost
        let mitm = configuration.mitmEnabled
        let hosts = configuration.tlsHostAllowlist
        let caDirectory = configuration.caDirectory
        let ready = DispatchSemaphore(value: 0)

        Task { [weak self] in
            do {
                if mitm {
                    await engine.setSSLScope(SSLScope(enabled: true, include: hosts))
                }
                let bound = try await engine.start(port: requestedPort, host: bindHost, observeTunnels: true)
                if let caDirectory {
                    do {
                        _ = try await engine.exportCA(toDirectory: caDirectory, pemName: "reticle-ca.pem", derName: "reticle-ca.cer")
                    } catch {
                        // Don't fail startup, but don't hide it either: a missing CA
                        // surfaces later as a misleading "file not found" in the
                        // device-trust / --proxy-install-ca flow.
                        self?.warn("CA export to \(caDirectory.path) failed; MITM device-trust files will be missing: \(error)")
                    }
                }
                // Claim the result under the lock. If the sync side already timed out
                // and abandoned this start, the engine is now bound but unowned — stop
                // it instead of leaking the port.
                let claimed: Bool = self?.lock.withLock {
                    guard let self, !self.startAbandoned else { return false }
                    self.startBound = bound
                    return true
                } ?? false
                if !claimed {
                    await engine.stop()
                }
            } catch {
                self?.lock.withLock { self?.startError = error }
            }
            ready.signal()
        }

        switch ready.wait(timeout: .now() + 30) {
        case .success:
            break
        case .timedOut:
            // The Task hasn't signaled yet, so it hasn't claimed a result; mark the
            // start abandoned so the Task stops the engine if it binds after this.
            lock.withLock { startAbandoned = true }
            throw NetworkProxyError.startTimedOut
        }
        let (bound, error) = lock.withLock { (startBound, startError) }
        if let error { throw error }
        if let bound { port = bound }
        syncRules()
        subscribe(engine: engine)
    }

    /// Rebinds the proxy LAN-wide and serves a phone-onboarding page (CA profile
    /// + QR) for the engine's CA, so a real device can install + trust it by
    /// scanning. Bridges the engine's async call to the daemon's sync lifecycle.
    public func startPhoneOnboarding() throws -> PhoneOnboarding {
        let engine = self.engine
        let box = OnboardingBox()
        let done = DispatchSemaphore(value: 0)
        Task { [weak self] in
            do {
                let info = try await engine.startPhoneOnboarding()
                // Claim, or tear down the provisioning server if the sync side gave up.
                let claimed: Bool = self?.lock.withLock {
                    guard let self, !self.onboardingAbandoned else { return false }
                    return true
                } ?? false
                if claimed { box.value = .success(info) }
                else { await engine.stopPhoneOnboarding() }
            } catch {
                box.value = .failure(error)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + 20) == .success else {
            lock.withLock { onboardingAbandoned = true }
            throw NetworkProxyError.startTimedOut
        }
        switch box.value {
        case .success(let info):
            // Map Loom's onboarding info to a Reticle-local value so the daemon
            // layer never has to import Loom's modules.
            return PhoneOnboarding(
                url: info.provisioningURL.absoluteString,
                proxyAddress: info.proxyAddress,
                fingerprint: info.fingerprint,
                qrPNG: info.qrPNGData
            )
        case .failure(let error): throw error
        case .none: throw NetworkProxyError.startTimedOut
        }
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

    /// Re-translates the whole rule set into the engine (full replace). Safe to
    /// call after any rule mutation; a no-op when no rule store is attached.
    public func syncRules() {
        guard let ruleStore else { return }
        let engine = self.engine
        // Snapshot + apply on the sync queue so a mutation callback fired while the
        // rule store still holds its lock only enqueues here (exportPackage, which
        // re-takes that lock, then runs off it).
        syncQueue.async { [weak self] in
            let export: NetworkRuleExport
            do {
                export = try ruleStore.exportPackage()
            } catch {
                // Critical: do NOT fall through to setRules([]) on an export failure —
                // that would silently wipe every active rule in the engine on a
                // transient disk/lock error, with no signal that capture behavior
                // just changed. Skip this sync and keep the last-applied rule set.
                self?.warn("skipped rule sync; exporting the rule set failed (keeping current rules): \(error)")
                return
            }
            let translated = LoomCaptureLane.translate(export)
            let done = DispatchSemaphore(value: 0)
            let errorBox = ErrorBox()
            Task {
                do { try await engine.setRules(translated) }
                catch { errorBox.error = error }
                done.signal()
            }
            if done.wait(timeout: .now() + 30) == .timedOut {
                self?.warn("rule sync timed out after 30s; the engine may be stalled")
                return
            }
            if let error = errorBox.error {
                self?.warn("rule sync failed to apply \(translated.count) rule(s): \(error)")
            }
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
        // A replayed flow is upserted into Loom's store by `replay(...)`, so it also
        // arrives here on the stream. Its evidence (request/response + diff) is owned
        // by the `network.replay` event the replay path emits synchronously, so skip
        // it to avoid a duplicate capture card.
        if flow.replayedFrom != nil { return }
        let requestId = flow.id.uuidString
        let firstSeen = lock.withLock { markSeenLocked(flow.id) }

        if firstSeen {
            var payload = makePayload(flow)
            var refs: [String: String] = [:]
            if let body = flow.request.body {
                storeBody(body, requestId: requestId, role: "request",
                          into: &refs, bytes: &payload.requestBodyBytes, truncated: &payload.requestBodyTruncated)
            }
            store.emit(factory.event(.request, payload: payload, refs: refs))
        }

        guard flow.completedAt != nil else { return }

        var payload = makePayload(flow)
        var refs: [String: String] = [:]
        if let body = flow.response?.body {
            storeBody(body, requestId: requestId, role: "response",
                      into: &refs, bytes: &payload.responseBodyBytes, truncated: &payload.responseBodyTruncated)
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
        // Loom marks an un-decrypted blind CONNECT tunnel with the CONNECT method
        // (only surfaced when the engine's observeTunnels is on); a decrypted
        // HTTPS exchange arrives as a normal flow, which implies MITM.
        let isTunnel = flow.request.method == "CONNECT"

        var payload = NetworkEventPayload(
            requestId: flow.id.uuidString,
            scheme: scheme,
            method: flow.request.method,
            url: flow.request.url,
            host: host,
            port: port,
            path: path,
            startMillis: Self.millis(flow.startedAt),
            tunnel: isTunnel,
            mitm: !isTunnel && scheme == "https"
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
        // A rule that acted is recorded on the flow as the rule name, which we set to
        // the Reticle rule id (see `translate`). We look the rule back up to carry the
        // route that fired (`ruleAction`) and, for a mock route, its value id.
        if let applied = flow.appliedRules?.first {
            payload.ruleApplied = true
            payload.ruleId = applied.name
            if let rule = ruleStore?.listRules().first(where: { $0.id == applied.name }) {
                payload.ruleAction = rule.actions.route.label
                payload.mockValueId = rule.mockValueId
            }
        }
        return payload
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: - Helpers

    /// Records that `id`'s request event was emitted, evicting the oldest id when the
    /// FIFO is full. Caller must hold `lock`. Returns true on first sighting.
    private func markSeenLocked(_ id: UUID) -> Bool {
        guard seen.insert(id).inserted else { return false }
        seenOrder.append(id)
        if seenOrder.count > seenCapacity {
            let evicted = seenOrder.removeFirst()
            seen.remove(evicted)
        }
        return true
    }

    /// Persists a captured body as an artifact and records its ref/size on the
    /// payload. A store failure is logged (not swallowed) so missing body evidence
    /// is distinguishable from a genuinely empty body.
    private func storeBody(
        _ body: Data,
        requestId: String,
        role: String,
        into refs: inout [String: String],
        bytes: inout Int?,
        truncated: inout Bool?
    ) {
        do {
            guard let stored = try bodyStore.store(body, requestId: requestId, role: role) else { return }
            refs[stored.refName] = stored.path
            bytes = stored.bytes
            truncated = stored.truncated
        } catch {
            warn("failed to store \(role) body for \(requestId); evidence will omit it: \(error)")
        }
    }

    /// Emits a non-fatal warning to stderr, matching the host's `warning: …` prefix
    /// convention. Capture never fails a request just because a side effect did.
    private func warn(_ message: String) {
        FileHandle.standardError.write(Data("warning: reticle capture: \(message)\n".utf8))
    }

    // MARK: - Replay

    /// Replays a captured flow by id with overrides, closing Loom's capture → modify
    /// → replay → diff loop. Bridges the engine's async API to the daemon's sync
    /// lifecycle. Emits one `network.replay` event (the replayed exchange + its diff
    /// against the original) and returns the diff to the caller. The replayed flow is
    /// re-sent host-side by Loom's forwarder, not through the device proxy.
    public func replay(requestId: String, request: NetworkReplayRequest) throws -> NetworkReplayResult {
        guard let sourceUUID = UUID(uuidString: requestId) else {
            throw NetworkReplayError.invalid("requestId is not a valid flow id: \(requestId)")
        }
        let overrides = try Self.translateOverrides(request)
        let engine = self.engine

        // The diff baseline: the original flow, still in the engine's in-memory store.
        let sourceBox = FlowBox()
        let sourceReady = DispatchSemaphore(value: 0)
        Task {
            sourceBox.flow = await engine.flow(id: sourceUUID)
            sourceReady.signal()
        }
        guard sourceReady.wait(timeout: .now() + 10) == .success else {
            throw NetworkReplayError.failed("fetching the source flow timed out")
        }
        guard let source = sourceBox.flow else {
            throw NetworkReplayError.notFound(
                "no captured flow with id \(requestId) (it may have aged out of the in-memory store)")
        }

        let box = ReplayResultBox()
        let done = DispatchSemaphore(value: 0)
        Task {
            do { box.result = .success(try await engine.replay(id: sourceUUID, overrides: overrides)) }
            catch { box.result = .failure(error) }
            done.signal()
        }
        guard done.wait(timeout: .now() + 35) == .success else {
            throw NetworkReplayError.failed("replay timed out")
        }
        switch box.result {
        case .success(let replayed):
            return emitReplay(source: source, replayed: replayed)
        case .failure(let error):
            // engine.replay upserts a failed flow but doesn't return it (and the stream
            // copy is skipped by `handle`), so emit a best-effort replay event here.
            return emitFailedReplay(source: source, error: error, request: request)
        case .none:
            throw NetworkReplayError.failed("replay produced no result")
        }
    }

    private func emitReplay(source: Flow, replayed: Flow) -> NetworkReplayResult {
        let newId = replayed.id.uuidString
        var payload = makePayload(replayed)
        var refs: [String: String] = [:]
        if let body = replayed.request.body {
            storeBody(body, requestId: newId, role: "request",
                      into: &refs, bytes: &payload.requestBodyBytes, truncated: &payload.requestBodyTruncated)
        }
        if let body = replayed.response?.body {
            storeBody(body, requestId: newId, role: "response",
                      into: &refs, bytes: &payload.responseBodyBytes, truncated: &payload.responseBodyTruncated)
        }
        let diff = NetworkReplayDiff.between(
            sourceStatus: source.statusCode,
            sourceHeaders: Self.headerMap(source.response?.headers),
            sourceBody: source.response?.body,
            replayStatus: replayed.statusCode,
            replayHeaders: Self.headerMap(replayed.response?.headers),
            replayBody: replayed.response?.body
        )
        payload.replayedFrom = source.id.uuidString
        payload.diff = diff
        store.emit(factory.event(.replay, payload: payload, refs: refs))
        return NetworkReplayResult(
            requestId: newId,
            replayedFrom: source.id.uuidString,
            status: replayed.statusCode,
            error: replayed.error,
            diff: diff
        )
    }

    private func emitFailedReplay(source: Flow, error: Error, request: NetworkReplayRequest) -> NetworkReplayResult {
        let newId = UUID().uuidString
        let url = request.url ?? source.request.url
        let method = request.method ?? source.request.method
        let components = URLComponents(string: url)
        let scheme = (components?.scheme ?? "http").lowercased()
        var payload = NetworkEventPayload(
            requestId: newId,
            scheme: scheme,
            method: method,
            url: url,
            host: components?.host ?? "",
            port: components?.port ?? (scheme == "https" ? 443 : 80),
            path: (components?.path).flatMap { $0.isEmpty ? nil : $0 } ?? "/",
            startMillis: Self.millis(Date()),
            tunnel: false,
            mitm: false
        )
        let message = (error as? NetworkReplayError)?.description ?? "\(error)"
        payload.error = message
        let diff = NetworkReplayDiff.between(
            sourceStatus: source.statusCode,
            sourceHeaders: Self.headerMap(source.response?.headers),
            sourceBody: source.response?.body,
            replayStatus: nil,
            replayHeaders: [:],
            replayBody: nil
        )
        payload.replayedFrom = source.id.uuidString
        payload.diff = diff
        store.emit(factory.event(.replay, payload: payload, refs: [:]))
        return NetworkReplayResult(
            requestId: newId,
            replayedFrom: source.id.uuidString,
            status: nil,
            error: message,
            diff: diff
        )
    }

    private static func translateOverrides(_ request: NetworkReplayRequest) throws -> ReplayOverrides {
        let bodyOverride: BodyOverride
        switch try request.resolvedBody() {
        case .none: bodyOverride = .keep
        case .some(.none): bodyOverride = .clear
        case .some(.some(let data)): bodyOverride = .replace(data)
        }
        let setHeaders = request.setHeaders.map { $0.map { HeaderPair(name: $0.key, value: $0.value) } }
        return ReplayOverrides(
            method: request.method,
            url: request.url,
            setHeaders: setHeaders,
            removeHeaders: request.removeHeaders,
            body: bodyOverride
        )
    }

    private static func headerMap(_ headers: [HeaderPair]?) -> [String: String] {
        var result: [String: String] = [:]
        for header in headers ?? [] { result[header.name] = header.value }
        return result
    }

    // MARK: - Rule translation

    /// Translates Reticle's traffic rules + values into Loom `TrafficRule`s. The Loom
    /// rule name carries the Reticle rule id so an applied rule is attributable back on
    /// the captured flow. Rules are ordered by descending priority to match Reticle's
    /// precedence (Loom applies the first matching rule). No-op rules (passthrough with
    /// no modifiers) are dropped so they can't fail Loom's "rule has no actions"
    /// validation and poison the whole atomic set. A `mock` route whose referenced
    /// value is missing is dropped for the same reason.
    private static func translate(_ export: NetworkRuleExport?) -> [TrafficRule] {
        guard let export else { return [] }
        let valuesById = Dictionary(export.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return export.rules
            .filter { !$0.actions.isNoOp }
            .sorted { $0.priority > $1.priority }
            .compactMap { rule in
                guard let route = translateRoute(rule.actions.route, valuesById: valuesById) else { return nil }
                let actions = RuleActions(
                    route: route,
                    rewriteRequest: translateRewriteRequest(rule.actions.rewriteRequest),
                    rewriteResponse: translateRewriteResponse(rule.actions.rewriteResponse),
                    requestSubstitutions: rule.actions.requestSubstitutions.map(translateSubstitution),
                    responseSubstitutions: rule.actions.responseSubstitutions.map(translateSubstitution),
                    delayMilliseconds: rule.actions.delayMs
                )
                return TrafficRule(
                    name: rule.id,
                    isEnabled: rule.enabled,
                    match: translateMatch(rule),
                    actions: actions
                )
            }
    }

    /// Maps a Reticle route onto Loom's. Returns nil to drop the rule when a `mock`
    /// route references a value that isn't in the export.
    private static func translateRoute(_ route: NetworkRoute, valuesById: [String: NetworkMockExportValue]) -> Route? {
        switch route {
        case .passthrough:
            return .passthrough
        case .block:
            return .block
        case .mock(let valueId):
            guard let value = valuesById[valueId] else { return nil }
            return .mock(MockResponseAction(
                statusCode: value.status,
                headers: value.headers.map { HeaderPair(name: $0.key, value: $0.value) },
                bodyBase64: value.bodyBase64,
                contentType: value.contentType
            ))
        case .mapRemote(let action):
            return .mapRemote(MapRemoteAction(destination: action.destination, keepHostHeader: action.keepHostHeader))
        }
    }

    private static func translateRewriteRequest(_ rewrite: NetworkHeaderRewrite?) -> RequestRewriteAction? {
        guard let rewrite, !rewrite.isEmpty else { return nil }
        return RequestRewriteAction(
            setHeaders: rewrite.setHeaders.map { HeaderPair(name: $0.key, value: $0.value) },
            removeHeaders: rewrite.removeHeaders
        )
    }

    private static func translateRewriteResponse(_ rewrite: NetworkHeaderRewrite?) -> ResponseRewriteAction? {
        guard let rewrite, !rewrite.isEmpty else { return nil }
        return ResponseRewriteAction(
            setHeaders: rewrite.setHeaders.map { HeaderPair(name: $0.key, value: $0.value) },
            removeHeaders: rewrite.removeHeaders
        )
    }

    private static func translateSubstitution(_ substitution: NetworkSubstitution) -> SubstitutionRule {
        let field: SubstitutionRule.Field
        switch substitution.field {
        case .url: field = .url
        case .header: field = .header
        case .body: field = .body
        }
        return SubstitutionRule(
            field: field,
            match: substitution.match,
            replacement: substitution.replacement,
            isRegex: substitution.isRegex,
            caseSensitive: substitution.caseSensitive
        )
    }

    private static func translateMatch(_ rule: NetworkRule) -> RuleMatch {
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
