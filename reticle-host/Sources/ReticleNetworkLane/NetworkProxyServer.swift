import Dispatch
import Foundation
import ReticleHostShared
import NIOCore
import NIOHTTP1
import NIOPosix

/// SwiftNIO HTTP proxy that publishes `network.*` events into a session store.
public final class NetworkProxyServer: @unchecked Sendable {
    private let store: any NetworkEventSink
    private let configuration: NetworkProxyConfiguration
    private let mockStore: NetworkMockStore?
    private let ready = DispatchSemaphore(value: 0)
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var channel: (any Channel)?
    private var startupError: Error?

    public private(set) var port: Int

    /// Creates a proxy server owned by the supplied session event store.
    public init(store: any NetworkEventSink, configuration: NetworkProxyConfiguration, mockStore: NetworkMockStore? = nil) throws {
        if configuration.mitmEnabled, let caDirectory = configuration.caDirectory {
            try ProxyCertificateStore(directory: caDirectory).validate()
        }
        self.store = store
        self.configuration = configuration
        self.mockStore = mockStore
        port = configuration.port
    }

    /// Starts accepting proxy connections.
    public func start() throws {
        let bodyStore = NetworkBodyStore(
            sessionDirectory: store.sessionDirectory,
            limitBytes: configuration.bodyLimitBytes
        )
        let factory = NetworkEventFactory(target: configuration.target)
        let policy = TlsInterceptionPolicy(
            enabled: configuration.mitmEnabled,
            allowlist: configuration.tlsHostAllowlist
        )
        let certificates = configuration.caDirectory.map(ProxyCertificateStore.init(directory:))
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .childChannelInitializer { [store] channel in
                channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder()), name: "proxy-http-decoder").flatMap {
                    channel.pipeline.addHandler(HTTPResponseEncoder(), name: "proxy-http-encoder")
                }.flatMap {
                    channel.pipeline.addHandler(NetworkProxyHandler(
                        store: store,
                        bodyStore: bodyStore,
                        factory: factory,
                        tlsPolicy: policy,
                        certificates: certificates,
                        mockStore: self.mockStore,
                        upstreamTimeoutSeconds: self.configuration.upstreamTimeoutSeconds
                    ))
                }
            }
        bootstrap.bind(host: configuration.bindHost, port: configuration.port).whenComplete { [weak self] result in
            guard let self else { return }
            self.lock.withLock {
                switch result {
                case .success(let channel):
                    self.channel = channel
                    if let bound = channel.localAddress?.port {
                        self.port = bound
                    }
                case .failure(let error):
                    self.startupError = error
                }
            }
            self.ready.signal()
        }
        // See ReticleHttpServer: the bind wait must tolerate a slow/cold CI
        // runner scheduling the bootstrap; it signals immediately on success.
        switch ready.wait(timeout: .now() + 30) {
        case .success:
            if let error = lock.withLock({ startupError }) { throw error }
        case .timedOut:
            throw NetworkProxyError.startTimedOut
        }
    }

    /// Stops accepting new proxy connections.
    public func stop() {
        lock.lock()
        let channel = channel
        self.channel = nil
        lock.unlock()
        _ = channel?.close()
        try? group.syncShutdownGracefully()
    }
}
