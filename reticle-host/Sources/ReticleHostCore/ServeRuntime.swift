import Foundation
import Dispatch
import Darwin

/// Options for running the local Reticle daemon.
public struct ServeOptions {
    public let session: String
    public let port: Int
    public let eventLimit: Int
    public let rootDirectory: URL
    public let discovery: DaemonDiscovery

    /// Creates daemon options with Reticle defaults.
    public init(args: Args) {
        session = args.option("session") ?? ServeOptions.defaultSessionName()
        port = Int(args.option("port") ?? "") ?? 9876
        eventLimit = Int(args.option("event-limit") ?? "") ?? 500
        rootDirectory = DaemonDiscovery.reticleHome().appendingPathComponent("sessions", isDirectory: true)
        discovery = DaemonDiscovery()
    }

    /// Default session name for ad-hoc serve runs.
    public static func defaultSessionName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "sess_\(formatter.string(from: now))"
    }
}

/// Owns the session store, HTTP server, and discovery lifecycle for `serve`.
public final class ServeRuntime {
    private let options: ServeOptions
    private var server: ReticleHttpServer?
    private let stopSemaphore = DispatchSemaphore(value: 0)
    private var signalSources: [DispatchSourceSignal] = []

    /// Creates a runtime for the supplied options.
    public init(options: ServeOptions) {
        self.options = options
    }

    /// Starts the daemon and blocks until interrupted.
    public func run() throws {
        let store = try EventStore(
            session: options.session,
            rootDirectory: options.rootDirectory,
            limit: options.eventLimit
        )
        let server = try ReticleHttpServer(store: store, port: options.port)
        self.server = server
        try server.start()

        let info = DaemonInfo(
            pid: getpid(),
            port: server.port,
            session: options.session,
            startedAt: Int64(Date().timeIntervalSince1970 * 1000)
        )
        try options.discovery.write(info)
        installSignalHandlers()

        print("reticle serve: session \(options.session)")
        print("reticle serve: http://127.0.0.1:\(server.port)")
        print("reticle serve: events \(store.eventsFile.path)")
        stopSemaphore.wait()
        stop()
    }

    /// Stops the server and removes owned discovery metadata.
    public func stop() {
        server?.stop()
        options.discovery.clearIfOwned(by: getpid())
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM]
        for sig in signals {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.stopSemaphore.signal()
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
