import Foundation
import ReticleHostShared
// Loom's SPM library products `LoomProxyCore` / `LoomSharedModels` expose the
// modules under their target names, which since Loom 0.0.5 carry the `Loom`
// prefix. No collision with Reticle's own module names.
import LoomProxyCore
import LoomSharedModels

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

/// Keeps `NSLock` rather than `Mutex`, for the same reason as `NetworkRuleStore`:
/// its locked sections call back into `self` (`markSeenLocked`, the drop-episode
/// bookkeeping), and `Mutex.withLock` hands its state over as `inout sending`,
/// which cannot be passed to a method on `self`. Every field the lock covers is
/// private to this type.
public final class LoomCaptureLane: @unchecked Sendable, FlowReplaying, FlowQuerying {
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
    /// Per-socket cursor into Loom's cumulative frame array: how many frames of this
    /// flow have already been emitted as events. Loom re-sends the whole array on every
    /// update, so without this every frame would be re-emitted on every update.
    private var frameCursor: [UUID: Int] = [:]
    /// Sockets whose cap notice has already gone out, so it is emitted exactly once.
    private var framesAnnounced = Set<UUID>()
    /// Frames emitted per socket before this lane stops and says so. Loom's own cap is
    /// 10k frames / 5 MB; mirroring that 1:1 into `events.jsonl` would let one chatty
    /// socket bury every other observation in the session.
    private static let frameCapacity = 1000
    /// Bytes of a text frame carried inline on its event. Above this the frame's
    /// payload is written as an artifact and the preview is marked truncated.
    private static let framePreviewBytes = 512
    /// Sockets tracked at once, bounded for the same reason `seen` is.
    private static let frameFlowCapacity = 256
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
    /// Serial worker that turns flows into events off the stream, so artifact writes
    /// never back-pressure the engine's `AsyncStream` into silently dropping flows.
    /// Serial on purpose: event order is evidence.
    private let drainQueue = DispatchQueue(label: "dev.reticle.loom.capture-drain")
    /// Flows accepted but not yet processed. Bounded for the same reason Loom bounds
    /// its stream — an unbounded backlog is just a memory leak with better manners.
    private var pendingCount = 0
    private var pendingDropped = 0
    /// `pendingDropped` as of the end of the last episode, so an episode's own loss
    /// is a subtraction rather than a second counter that can disagree with the total.
    private var episodeDroppedBase = 0
    /// True once the current overflow episode has been announced, cleared when the
    /// backlog drains under half so a later overflow is announced again.
    private var dropEpisodeAnnounced = false
    private static let pendingCapacity = 4096

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
        let box = OneShot<Result<PhoneOnboardingInfo, Error>>()
        Task { [weak self] in
            do {
                let info = try await engine.startPhoneOnboarding()
                // Claim, or tear down the provisioning server if the sync side gave up.
                let claimed: Bool = self?.lock.withLock {
                    guard let self, !self.onboardingAbandoned else { return false }
                    return true
                } ?? false
                if claimed { box.resolve(.success(info)) }
                else { await engine.stopPhoneOnboarding() }
            } catch {
                box.resolve(.failure(error))
            }
        }
        // A claim that lost the race resolves nothing, so this also covers the
        // "engine answered but the sync side had already given up" case.
        guard let outcome = box.wait(seconds: 20) else {
            lock.withLock { onboardingAbandoned = true }
            throw NetworkProxyError.startTimedOut
        }
        switch outcome {
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
            let reportBox = OneShot<SetRulesReport>()
            Task {
                reportBox.resolve(await engine.setRules(translated))
            }
            guard let report = reportBox.wait(seconds: 30) else {
                self?.warn("rule sync timed out after 30s; the engine may be stalled")
                return
            }
            // Since Loom 0.0.5 `setRules` degrades instead of throwing: it applies every
            // rule that validates and reports the rest. Silence here would mean an agent
            // adds a mock, gets no error, and sees live traffic anyway — so name each
            // rule that did not make it in.
            for rejection in report.rejected {
                self?.warn("rule \(rejection.name) was rejected by the engine and is NOT active: \(rejection.reason)")
            }
        }
    }

    /// Subscribes to the engine's flow stream, doing nothing on the stream itself but
    /// handing each flow to a worker.
    ///
    /// The split is the point. `handle` writes body and frame artifacts to disk, and
    /// doing that inline made this loop the slow consumer of an `AsyncStream` that
    /// Loom buffers with `.bufferingOldest(512)` — so a burst of traffic silently
    /// dropped the *newest* flows, and `AsyncStream` gives a subscriber no way to
    /// learn it happened. Draining instantly moves the backlog to a queue Reticle
    /// owns, which is bounded the same way but, unlike the stream, can count what it
    /// drops and say so.
    private func subscribe(engine: ProxyEngine) {
        streamTask = Task { [weak self] in
            let stream = await engine.flowStream()
            for await flow in stream {
                if Task.isCancelled { break }
                self?.enqueue(flow)
            }
        }
    }

    /// Test seams. Overflow is only reachable when the worker is slower than arrival,
    /// which a test has to stage deliberately rather than hope for; `waitForDrain`
    /// then makes "the worker has caught up" an assertable fact instead of a sleep.
    /// Internal, not public — nothing outside the lane's own tests can reach them.
    func suspendDrainForTesting() { drainQueue.suspend() }
    func resumeDrainForTesting() { drainQueue.resume() }
    func waitForDrain() { drainQueue.sync {} }

    /// Takes a flow off the stream and schedules it, never touching the disk here.
    /// When the backlog is full the flow is dropped and an advisory is emitted — a
    /// bounded queue is a deliberate memory choice, but a silent one would make a
    /// gap in the evidence indistinguishable from traffic that never happened.
    func enqueue(_ flow: Flow) {
        enum Outcome { case accepted, dropped(total: Int, announce: Bool) }

        let outcome: Outcome = lock.withLock {
            guard pendingCount < Self.pendingCapacity else {
                pendingDropped += 1
                // One advisory per episode: announce when the backlog first overflows,
                // and re-arm only once it has drained back under half. A drop storm
                // must not itself become the flood that buries the session.
                let announce = !dropEpisodeAnnounced
                dropEpisodeAnnounced = true
                return .dropped(total: pendingDropped, announce: announce)
            }
            pendingCount += 1
            return .accepted
        }

        switch outcome {
        case .dropped(let total, let announce):
            guard announce else { return }
            let message = "capture backlog full (\(Self.pendingCapacity) flows); "
                + "dropping new flows until it drains — \(total) dropped so far this session"
            warn(message)
            store.emit(factory.event(advisory: NetworkAdvisoryPayload(
                kind: "capture-backlog-overflow",
                message: message,
                droppedFlowsTotal: total
            )))
        case .accepted:
            drainQueue.async { [weak self] in
                guard let self else { return }
                self.handle(flow)
                // Close the episode only once the backlog is genuinely clear (half the
                // capacity), not the instant it dips below full — otherwise a queue
                // hovering at the limit would alternate overflow/recovered forever.
                let recovered: (episode: Int, total: Int)? = self.lock.withLock {
                    self.pendingCount -= 1
                    guard self.dropEpisodeAnnounced,
                          self.pendingCount <= Self.pendingCapacity / 2 else { return nil }
                    self.dropEpisodeAnnounced = false
                    let episode = self.pendingDropped - self.episodeDroppedBase
                    self.episodeDroppedBase = self.pendingDropped
                    return (episode, self.pendingDropped)
                }
                guard let recovered else { return }
                let message = "capture backlog recovered; \(recovered.episode) flow(s) were not recorded "
                    + "during the overflow — \(recovered.total) dropped so far this session"
                self.warn(message)
                var payload = NetworkAdvisoryPayload(
                    kind: "capture-backlog-recovered",
                    message: message,
                    droppedFlowsTotal: recovered.total
                )
                payload.droppedFlows = recovered.episode
                self.store.emit(self.factory.event(advisory: payload))
            }
        }
    }

    /// Translates one Loom `Flow` update into the network event stream: a
    /// `network.request` on first sighting, then `network.response`/`network.error`
    /// once the exchange completes. Loom yields the same flow id twice (start, then
    /// completion), which maps cleanly onto the two events.
    /// Internal rather than private so the tests can drive it with a synthesized
    /// `Flow`: this is the whole flow-to-evidence normalization, and the WebSocket
    /// path in particular is not reachable from the socket-less proxy e2e.
    func handle(_ flow: Flow) {
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
                storeBody(body, wireBytes: flow.request.fullBodyBytes, requestId: requestId, role: "request",
                          into: &refs, bytes: &payload.requestBodyBytes, truncated: &payload.requestBodyTruncated)
            }
            store.emit(factory.event(.request, payload: payload, refs: refs))
        }

        // A WebSocket keeps yielding while it is open, carrying the frames recorded so
        // far. Frames are emitted before the completion guard on purpose: a socket may
        // stay open for the whole session, so waiting for `completedAt` would mean
        // holding every frame back until a close that never comes.
        if flow.webSocketMessages != nil {
            emitWebSocketFrames(flow)
        }

        guard flow.completedAt != nil else { return }

        var payload = makePayload(flow)
        var refs: [String: String] = [:]
        if let response = flow.response, let body = response.body {
            storeBody(body, wireBytes: response.fullBodyBytes, requestId: requestId, role: "response",
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
        if let firstByteAt = flow.firstByteAt {
            payload.firstByteMillis = Self.millis(firstByteAt)
        }
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
        // Imported traffic (a HAR loaded into the engine) rides the same live stream
        // as captured traffic. It is still evidence — it can be inspected, diffed and
        // replayed — but it is evidence of somebody else's session, so it says so.
        if let importedFrom = flow.importedFrom {
            payload.importedFrom = importedFrom
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

    // MARK: - WebSocket frames

    /// Emits one `network.websocket` event per frame this lane has not emitted yet,
    /// then — once, at the moment it becomes true — the notice that recording stopped.
    ///
    /// Loom hands over the whole cumulative frame array on every update, so the
    /// per-flow cursor is what makes this incremental. Two caps sit above it and both
    /// have to be audible: Reticle's own `frameCapacity` (an event per frame would
    /// otherwise let one chatty socket dominate `events.jsonl`) and Loom's 10k-frame /
    /// 5 MB cap, which can bite first on a few large frames. Either way the socket is
    /// still open and still talking; silence afterwards must not read as a quiet socket.
    private func emitWebSocketFrames(_ flow: Flow) {
        let messages = flow.webSocketMessages ?? []
        let dropped = flow.webSocketDroppedMessages
        let requestId = flow.id.uuidString

        let (start, alreadyAnnounced) = lock.withLock {
            (frameCursor[flow.id] ?? 0, framesAnnounced.contains(flow.id))
        }
        guard start < messages.count || (dropped != nil && !alreadyAnnounced) else { return }

        let components = URLComponents(string: flow.request.url)
        let host = components?.host ?? ""
        let limit = min(messages.count, Self.frameCapacity)

        var emitted = start
        for index in start..<max(start, limit) {
            let message = messages[index]
            var payload = NetworkWebSocketPayload(
                requestId: requestId,
                url: flow.request.url,
                host: host,
                frameIndex: index,
                direction: message.direction == .clientToServer ? "clientToServer" : "serverToClient",
                kind: message.kind.rawValue,
                isFinal: message.isFinal,
                bytes: message.payload.count,
                frameMillis: Self.millis(message.timestamp)
            )
            var refs: [String: String] = [:]
            if message.kind == .text, let text = String(data: message.payload.prefix(Self.framePreviewBytes), encoding: .utf8) {
                payload.textPreview = text
                if message.payload.count > Self.framePreviewBytes { payload.textPreviewTruncated = true }
            }
            // Small frames live entirely in the event; only what the preview can't hold
            // becomes a file, so a chatty socket doesn't strew thousands of artifacts.
            if message.payload.count > Self.framePreviewBytes {
                do {
                    if let stored = try bodyStore.storeFrame(message.payload, requestId: requestId, index: index) {
                        refs[stored.refName] = stored.path
                    }
                } catch {
                    warn("failed to store WebSocket frame \(index) for \(requestId); evidence will omit its payload: \(error)")
                }
            }
            store.emit(factory.event(webSocket: payload, refs: refs))
            emitted = index + 1
        }

        let capReached = messages.count >= Self.frameCapacity || dropped != nil
        let announce: Bool = lock.withLock {
            frameCursor[flow.id] = emitted
            trimFrameCursorLocked(keeping: flow.id)
            guard capReached, !framesAnnounced.contains(flow.id) else { return false }
            framesAnnounced.insert(flow.id)
            return true
        }
        guard announce else { return }

        var notice = NetworkWebSocketPayload(
            requestId: requestId,
            url: flow.request.url,
            host: host,
            frameIndex: emitted,
            direction: "none",
            kind: "capReached",
            isFinal: true,
            bytes: 0,
            frameMillis: Self.millis(Date())
        )
        notice.capReached = true
        notice.framesRecorded = emitted
        notice.framesNotRecorded = dropped
        store.emit(factory.event(webSocket: notice))
        warn("WebSocket \(requestId) hit a frame capture cap after \(emitted) frame(s); "
            + "the socket is still open and later frames are NOT recorded")
    }

    /// Bounds the per-flow frame bookkeeping the same way `seen` is bounded — a daemon
    /// that outlives many sockets must not accumulate an entry per socket forever.
    /// Caller must hold `lock`.
    private func trimFrameCursorLocked(keeping id: UUID) {
        guard frameCursor.count > Self.frameFlowCapacity else { return }
        for key in frameCursor.keys where key != id {
            frameCursor.removeValue(forKey: key)
            framesAnnounced.remove(key)
            if frameCursor.count <= Self.frameFlowCapacity { return }
        }
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
    ///
    /// `wireBytes` is Loom's `fullBodyBytes`: non-nil only when Loom's own capture
    /// cap already clipped `body` before we saw it. Reticle's cap is not the only
    /// one in the chain, so it has to be carried — otherwise a body Loom clipped
    /// reports its prefix length as the size and `truncated: false`, and an agent
    /// reading that concludes the server returned malformed JSON.
    private func storeBody(
        _ body: Data,
        wireBytes: Int?,
        requestId: String,
        role: String,
        into refs: inout [String: String],
        bytes: inout Int?,
        truncated: inout Bool?
    ) {
        do {
            let stored: NetworkBodyStore.StoredBody?
            if let wireBytes {
                stored = try bodyStore.store(
                    prefix: body, totalBytes: max(wireBytes, body.count), requestId: requestId, role: role)
            } else {
                stored = try bodyStore.store(body, requestId: requestId, role: role)
            }
            guard let stored else { return }
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

    // MARK: - Flow query

    /// Finds replayable flows matching `filter`. The scan runs inside Loom's store
    /// over everything retained and only then applies the limit, so a match older
    /// than the newest `limit` exchanges is still findable — the reason to filter
    /// here rather than pull summaries and sift them in an agent's context.
    public func listFlows(matching filter: NetworkFlowFilter) throws -> NetworkFlowQueryResult {
        let engine = self.engine
        let query = Self.translateFilter(filter)
        let box = OneShot<[Flow]>()
        Task {
            // Ask for one more than the limit purely to learn whether the list was
            // clipped, so `truncatedToLimit` is a fact rather than a guess from a
            // full page.
            box.resolve(await engine.recentFlows(matching: query, limit: filter.limit + 1))
        }
        guard let matched = box.wait(seconds: 15) else {
            throw NetworkReplayError.failed("listing flows timed out")
        }

        let clipped = matched.count > filter.limit
        let page = clipped ? Array(matched.prefix(filter.limit)) : matched
        return NetworkFlowQueryResult(
            flows: page.map(Self.summarize),
            truncatedToLimit: clipped,
            replayableOnly: true
        )
    }

    private static func summarize(_ flow: Flow) -> NetworkFlowSummary {
        let truncated = flow.request.isBodyTruncated || (flow.response?.isBodyTruncated ?? false)
        return NetworkFlowSummary(
            requestId: flow.id.uuidString,
            method: flow.request.method,
            url: flow.request.url,
            host: flow.host ?? "",
            status: flow.statusCode,
            error: flow.error,
            startMillis: millis(flow.startedAt),
            durationMs: flow.durationMS,
            ttfbMs: flow.ttfbMS,
            receiveMs: flow.receiveMS,
            requestBodyBytes: flow.request.fullBodyBytes ?? flow.request.body?.count,
            responseBodyBytes: flow.response?.fullBodyBytes ?? flow.response?.body?.count,
            bodyCaptureTruncated: truncated ? true : nil,
            importedFrom: flow.importedFrom
        )
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
        let sourceBox = OneShot<Flow?>()
        Task {
            sourceBox.resolve(await engine.flow(id: sourceUUID))
        }
        guard let found = sourceBox.wait(seconds: 10) else {
            throw NetworkReplayError.failed("fetching the source flow timed out")
        }
        guard let source = found else {
            throw NetworkReplayError.notFound(
                "no captured flow with id \(requestId) (it may have aged out of the in-memory store)")
        }

        let box = OneShot<Result<Flow, Error>>()
        Task {
            do { box.resolve(.success(try await engine.replay(id: sourceUUID, overrides: overrides))) }
            catch { box.resolve(.failure(error)) }
        }
        guard let outcome = box.wait(seconds: 35) else {
            throw NetworkReplayError.failed("replay timed out")
        }
        switch outcome {
        case .success(let replayed):
            return emitReplay(source: source, replayed: replayed)
        case .failure(let error):
            // engine.replay upserts a failed flow but doesn't return it (and the stream
            // copy is skipped by `handle`), so emit a best-effort replay event here.
            return emitFailedReplay(source: source, error: error, request: request)
        }
    }

    private func emitReplay(source: Flow, replayed: Flow) -> NetworkReplayResult {
        let newId = replayed.id.uuidString
        var payload = makePayload(replayed)
        var refs: [String: String] = [:]
        if let body = replayed.request.body {
            storeBody(body, wireBytes: replayed.request.fullBodyBytes, requestId: newId, role: "request",
                      into: &refs, bytes: &payload.requestBodyBytes, truncated: &payload.requestBodyTruncated)
        }
        if let response = replayed.response, let body = response.body {
            storeBody(body, wireBytes: response.fullBodyBytes, requestId: newId, role: "response",
                      into: &refs, bytes: &payload.responseBodyBytes, truncated: &payload.responseBodyTruncated)
        }
        let diff = NetworkReplayDiff.between(
            sourceStatus: source.statusCode,
            sourceHeaders: Self.headerMap(source.response?.headers),
            sourceBody: source.response?.body,
            sourceWireBytes: source.response?.fullBodyBytes,
            replayStatus: replayed.statusCode,
            replayHeaders: Self.headerMap(replayed.response?.headers),
            replayBody: replayed.response?.body,
            replayWireBytes: replayed.response?.fullBodyBytes
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
            sourceWireBytes: source.response?.fullBodyBytes,
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

}
