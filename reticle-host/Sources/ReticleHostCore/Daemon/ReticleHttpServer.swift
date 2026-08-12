import Foundation
import Synchronization
import Hummingbird
import NIOCore

/// Localhost REST/SSE server backing `reticle serve`.
public final class ReticleHttpServer: Sendable {
    private let store: EventStore
    private let ruleStore: NetworkRuleStore?
    private let helper: HelperCalling?
    private let ready = DispatchSemaphore(value: 0)
    private let traceIngest = ActionTraceIngest()

    /// Everything that changes after `init`. It is all touched from at least two
    /// threads — the caller's, Hummingbird's `onServerRunning`, and the run task —
    /// so it lives in one mutex instead of a lock plus five loose fields. `port`
    /// is in here because a 0 (ephemeral) port is rewritten on bind.
    private struct Live {
        var runTask: Task<Void, Error>?
        var serverChannel: (any Channel)?
        var startupError: Error?
        var flowReplayer: FlowReplaying?
        var flowQuerier: FlowQuerying?
        var port: Int
    }
    private let live: Mutex<Live>

    /// The capture lane that services flow replays, bound after the server starts
    /// (the lane is created once the proxy port is known). nil until then / when
    /// capture is disabled, in which case the replay route answers 404.
    public var flowReplayer: FlowReplaying? {
        get { live.withLock { $0.flowReplayer } }
        set { live.withLock { $0.flowReplayer = newValue } }
    }

    /// Bound alongside the replayer: listing exists to find something to replay, so
    /// the two are available together or not at all.
    public var flowQuerier: FlowQuerying? {
        get { live.withLock { $0.flowQuerier } }
        set { live.withLock { $0.flowQuerier = newValue } }
    }

    public var port: Int { live.withLock { $0.port } }

    /// Creates a daemon HTTP server on `port`; pass 0 for an ephemeral port.
    public init(
        store: EventStore,
        port: Int,
        ruleStore: NetworkRuleStore? = nil,
        helper: HelperCalling? = nil
    ) throws {
        self.store = store
        self.ruleStore = ruleStore
        self.helper = helper
        self.live = Mutex(Live(port: port))
    }

    /// Starts listening and waits until Hummingbird reports the server channel.
    public func start() throws {
        let router = buildRouter()
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname("127.0.0.1", port: port),
                serverName: "reticle-serve"
            ),
            onServerRunning: { [weak self] channel in
                guard let self else { return }
                self.live.withLock { live in
                    live.serverChannel = channel
                    if let boundPort = channel.localAddress?.port {
                        live.port = boundPort
                    }
                }
                self.ready.signal()
            }
        )
        let runTask = Task { [weak self] in
            do {
                try await app.runService(gracefulShutdownSignals: [])
            } catch {
                guard let self else { throw error }
                self.live.withLock { $0.startupError = error }
                self.ready.signal()
                throw error
            }
        }
        live.withLock { $0.runTask = runTask }
        // Generous bind wait: onServerRunning signals the instant the socket is
        // bound (so the success path pays nothing), but Hummingbird runs on a
        // Task and a loaded/cold CI runner can take well over 5s just to
        // schedule it — a tight bound turned that into a flaky failure. A real
        // bind error still surfaces immediately via startupError.
        switch ready.wait(timeout: .now() + Self.startupTimeoutSeconds) {
        case .success:
            if let error = live.withLock({ $0.startupError }) {
                throw error
            }
        case .timedOut:
            throw ReticleHttpServerError.startTimedOut
        }
    }

    private static let startupTimeoutSeconds: Double = 30

    /// Stops accepting new connections.
    public func stop() {
        let (channel, runTask) = live.withLock { live -> ((any Channel)?, Task<Void, Error>?) in
            defer { live.serverChannel = nil; live.runTask = nil }
            return (live.serverChannel, live.runTask)
        }
        if let channel {
            _ = channel.close()
        } else {
            runTask?.cancel()
        }
    }

    private func buildRouter() -> Router<BasicRequestContext> {
        let router = Router()
        ReticleSessionRoutes(store: store, traceIngest: traceIngest, port: { [weak self] in self?.port ?? 0 }).register(on: router)
        ReticleRuleRoutes(ruleStore: ruleStore).register(on: router)
        ReticleFlowRoutes(
            replayer: { [weak self] in self?.flowReplayer },
            querier: { [weak self] in self?.flowQuerier }
        ).register(on: router)
        ReticleHelperRoutes(helper: helper).register(on: router)
        ReticleStreamRoutes(store: store).register(on: router)
        return router
    }
}

public enum ReticleHttpServerError: Error, CustomStringConvertible {
    case startTimedOut

    public var description: String {
        switch self {
        case .startTimedOut:
            "reticle serve did not report a listening socket within 30 seconds"
        }
    }
}
