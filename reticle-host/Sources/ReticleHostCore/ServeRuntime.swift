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
    public let serial: String?
    public let proxyPort: Int?
    public let proxyDevice: Bool
    public let proxyMitm: Bool
    public let proxyCaDirectory: URL?
    public let proxyInstallCa: Bool
    public let proxyTlsHosts: [String]
    public let helper: String?
    public let helperBroker: Bool

    /// Creates daemon options with Reticle defaults.
    public init(args: Args) {
        session = args.option("session") ?? ServeOptions.defaultSessionName()
        port = Int(args.option("port") ?? "") ?? 9876
        eventLimit = Int(args.option("event-limit") ?? "") ?? 500
        rootDirectory = DaemonDiscovery.reticleHome().appendingPathComponent("sessions", isDirectory: true)
        discovery = DaemonDiscovery()
        serial = args.option("serial").flatMap { $0 == "true" ? nil : $0 }
        proxyPort = args.option("proxy-port").map { Int($0) ?? 9090 }
        proxyDevice = args.option("proxy-device") == "true"
        proxyMitm = args.option("proxy-mitm") == "true"
        proxyCaDirectory = args.option("proxy-ca-dir").map { URL(fileURLWithPath: $0) }
            ?? (args.option("proxy-mitm") == "true" || args.option("proxy-install-ca") == "true"
                ? DaemonDiscovery.reticleHome().appendingPathComponent("proxy-ca", isDirectory: true)
                : nil)
        proxyInstallCa = args.option("proxy-install-ca") == "true"
        proxyTlsHosts = args.option("proxy-ssl-hosts")?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        helper = resolveHelper(args)
        helperBroker = args.option("helper-broker") == "true"
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
    private var proxyServer: NetworkProxyServer?
    private var proxyRestore: DeviceProxyRestore?
    private var helperBroker: HelperClient?
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
        let mockStore = try NetworkMockStore(sessionDirectory: store.sessionDirectory)
        let broker = try startHelperBrokerIfNeeded()
        let server: ReticleHttpServer
        do {
            server = try ReticleHttpServer(store: store, port: options.port, mockStore: mockStore, helper: broker)
            self.server = server
            try server.start()
        } catch {
            helperBroker?.shutdown()
            helperBroker = nil
            throw error
        }
        if let proxyPort = effectiveProxyPort {
            let certificates = try options.proxyCaDirectory.map { store in
                let certificates = ProxyCertificateStore(directory: store)
                try certificates.validate()
                return certificates
            }
            if options.proxyInstallCa, let certificates {
                try installCA(certificates)
            }
            let proxy = try NetworkProxyServer(
                store: store,
                configuration: NetworkProxyConfiguration(
                    port: proxyPort,
                    target: options.serial.map { "android:\($0)" },
                    mitmEnabled: options.proxyMitm,
                    caDirectory: options.proxyCaDirectory,
                    tlsHostAllowlist: options.proxyTlsHosts
                ),
                mockStore: mockStore
            )
            try proxy.start()
            proxyServer = proxy
            if options.proxyDevice {
                proxyRestore = try configureDeviceProxy(port: proxy.port)
            }
        }

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
        if options.helperBroker {
            print("reticle serve: helper broker enabled")
        }
        if let proxyServer {
            print("reticle serve: proxy http://127.0.0.1:\(proxyServer.port)")
        }
        if let ca = options.proxyCaDirectory {
            print("reticle serve: ca \(ca.appendingPathComponent("reticle-ca.cer").path)")
        }
        print("reticle serve: events \(store.eventsFile.path)")
        fflush(stdout)
        stopSemaphore.wait()
        stop()
    }

    /// Stops the server and removes owned discovery metadata.
    public func stop() {
        restoreDeviceProxy()
        helperBroker?.shutdown()
        helperBroker = nil
        proxyServer?.stop()
        server?.stop()
        options.discovery.clearIfOwned(by: getpid())
    }

    private func startHelperBrokerIfNeeded() throws -> HelperClient? {
        guard options.helperBroker else { return nil }
        guard let helper = options.helper else {
            throw HelperError("could not find reticle-helper for --helper-broker")
        }
        let client = HelperClient(
            launcher: helper,
            javaHome: ProcessInfo.processInfo.environment["JAVA_HOME"],
            serial: options.serial
        )
        try client.start()
        helperBroker = client
        return client
    }

    private var effectiveProxyPort: Int? {
        if let proxyPort = options.proxyPort { return proxyPort }
        if options.proxyDevice || options.proxyMitm { return 9090 }
        return nil
    }

    private func configureDeviceProxy(port: Int) throws -> DeviceProxyRestore? {
        guard let helper = options.helper else {
            throw HelperError("could not find reticle-helper for --proxy-device")
        }
        let client = HelperClient(
            launcher: helper,
            javaHome: ProcessInfo.processInfo.environment["JAVA_HOME"],
            serial: options.serial
        )
        try client.start()
        defer { client.shutdown() }
        let result = try client.call("proxySet", ["host": "127.0.0.1", "port": port])
        return DeviceProxyRestore(previous: result["previous"] as? String, proxyPort: port, helper: helper, serial: options.serial)
    }

    private func installCA(_ certificates: ProxyCertificateStore) throws {
        guard let helper = options.helper else {
            throw HelperError("could not find reticle-helper for --proxy-install-ca")
        }
        let client = HelperClient(
            launcher: helper,
            javaHome: ProcessInfo.processInfo.environment["JAVA_HOME"],
            serial: options.serial
        )
        try client.start()
        defer { client.shutdown() }
        _ = try client.call("proxyInstallCa", [
            "path": certificates.caCertificateDER.path,
            "name": "Reticle Local Debug CA"
        ])
    }

    private func restoreDeviceProxy() {
        guard let restore = proxyRestore else { return }
        let client = HelperClient(
            launcher: restore.helper,
            javaHome: ProcessInfo.processInfo.environment["JAVA_HOME"],
            serial: restore.serial
        )
        do {
            try client.start()
            _ = try client.call("proxyClear", ["port": restore.proxyPort])
            if let previous = restore.previous, !previous.isEmpty {
                _ = try client.call("proxySet", ["value": previous])
            }
        } catch {
            FileHandle.standardError.write(Data("warning: could not restore device proxy: \(error)\n".utf8))
        }
        client.shutdown()
    }

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM]
        for sig in signals {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [weak self] in
                self?.stopSemaphore.signal()
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

private struct DeviceProxyRestore {
    let previous: String?
    let proxyPort: Int
    let helper: String
    let serial: String?
}
