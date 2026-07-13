import Foundation
import Hummingbird
import NIOCore

/// Localhost REST/SSE server backing `reticle serve`.
public final class ReticleHttpServer: @unchecked Sendable {
    private let store: EventStore
    private let mockStore: NetworkMockStore?
    private let helper: HelperCalling?
    private let ready = DispatchSemaphore(value: 0)
    private let traceIngest = ActionTraceIngest()
    private let lock = NSLock()
    private var runTask: Task<Void, Error>?
    private var serverChannel: (any Channel)?
    private var startupError: Error?

    public private(set) var port: Int

    /// Creates a daemon HTTP server on `port`; pass 0 for an ephemeral port.
    public init(
        store: EventStore,
        port: Int,
        mockStore: NetworkMockStore? = nil,
        helper: HelperCalling? = nil
    ) throws {
        self.store = store
        self.mockStore = mockStore
        self.helper = helper
        self.port = port
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
                self.lock.withLock {
                    self.serverChannel = channel
                    if let boundPort = channel.localAddress?.port {
                        self.port = boundPort
                    }
                }
                self.ready.signal()
            }
        )
        runTask = Task { [weak self] in
            do {
                try await app.runService(gracefulShutdownSignals: [])
            } catch {
                guard let self else { throw error }
                self.lock.withLock {
                    self.startupError = error
                }
                self.ready.signal()
                throw error
            }
        }
        // Generous bind wait: onServerRunning signals the instant the socket is
        // bound (so the success path pays nothing), but Hummingbird runs on a
        // Task and a loaded/cold CI runner can take well over 5s just to
        // schedule it — a tight bound turned that into a flaky failure. A real
        // bind error still surfaces immediately via startupError.
        switch ready.wait(timeout: .now() + Self.startupTimeoutSeconds) {
        case .success:
            if let error = lock.withLock({ startupError }) {
                throw error
            }
        case .timedOut:
            throw ReticleHttpServerError.startTimedOut
        }
    }

    private static let startupTimeoutSeconds: Double = 30

    /// Stops accepting new connections.
    public func stop() {
        lock.lock()
        let channel = serverChannel
        serverChannel = nil
        lock.unlock()
        if let channel {
            _ = channel.close()
        } else {
            runTask?.cancel()
        }
        runTask = nil
    }

    private func buildRouter() -> Router<BasicRequestContext> {
        let router = Router()
        ReticleSessionRoutes(store: store, traceIngest: traceIngest, port: { [weak self] in self?.port ?? 0 }).register(on: router)
        ReticleMockRoutes(mockStore: mockStore).register(on: router)
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
