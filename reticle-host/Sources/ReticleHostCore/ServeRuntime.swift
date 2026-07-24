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
    public let target: String
    public let serial: String?
    public let proxyPort: Int?
    public let proxyBind: String
    public let proxyDevice: Bool
    public let proxyMitm: Bool
    public let proxyCaDirectory: URL?
    public let proxyInstallCa: Bool
    public let proxyTlsHosts: [String]
    /// `--proxy-max-request-body-mb`: in-memory buffering cap for one proxied
    /// request body; oversized uploads get 413 instead of ballooning the daemon.
    public let proxyMaxRequestBodyBytes: Int?
    /// `--proxy-phone-onboard`: rebind the proxy LAN-wide and serve a
    /// CA profile + QR page so a real device can install + trust the CA by
    /// scanning — the QR-based path for iOS real devices where `simctl` can't help.
    public let proxyPhoneOnboard: Bool
    public let helper: String?
    public let helperBroker: Bool

    /// Creates daemon options with Reticle defaults.
    public init(args: Args) {
        session = args.option("session") ?? ServeOptions.defaultSessionName()
        port = Int(args.option("port") ?? "") ?? 9876
        eventLimit = Int(args.option("event-limit") ?? "") ?? 500
        rootDirectory = DaemonDiscovery.reticleHome().appendingPathComponent("sessions", isDirectory: true)
        discovery = DaemonDiscovery()
        target = args.option("target") ?? "android"
        serial = args.option("serial").flatMap { $0 == "true" ? nil : $0 }
        proxyPort = args.option("proxy-port").map { Int($0) ?? 9090 }
        proxyBind = args.option("proxy-bind") ?? "127.0.0.1"
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
        proxyMaxRequestBodyBytes = args.option("proxy-max-request-body-mb")
            .flatMap { Int($0) }
            .map { $0 * 1024 * 1024 }
        proxyPhoneOnboard = args.option("proxy-phone-onboard") == "true"
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
    private var loomLane: LoomCaptureLane?
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
        let ruleStore = try NetworkRuleStore(sessionDirectory: store.sessionDirectory)
        let broker = try startHelperBrokerIfNeeded()
        let server: ReticleHttpServer
        do {
            server = try ReticleHttpServer(store: store, port: options.port, ruleStore: ruleStore, helper: broker)
            self.server = server
            try server.start()
        } catch {
            helperBroker?.shutdown()
            helperBroker = nil
            throw error
        }
        if let proxyPort = effectiveProxyPort {
            // Attribute captured traffic to the platform target. iOS shares the
            // host network, so the serial is the booted simulator's udid.
            let attributedSerial = options.serial
                ?? (options.target == "ios" ? try? Simctl.resolveUdid(nil) : nil)
            let configuration = NetworkProxyConfiguration(
                port: proxyPort,
                bindHost: options.proxyBind,
                target: attributedSerial.map { "\(options.target):\($0)" },
                maxRequestBodyBytes: options.proxyMaxRequestBodyBytes
                    ?? NetworkProxyConfiguration.defaultMaxRequestBodyBytes,
                mitmEnabled: options.proxyMitm,
                caDirectory: options.proxyCaDirectory,
                tlsHostAllowlist: options.proxyTlsHosts
            )
            // Capture runs on Loom's engine (LoomCaptureLane). The lane generates
            // and exports the CA (reticle-ca.cer/.pem) into caDirectory on start.
            let lane = LoomCaptureLane(store: store, configuration: configuration, ruleStore: ruleStore)
            ruleStore.onChange = { [weak lane] in lane?.syncRules() }
            try lane.start()
            // The lane is created after the server starts, so bind it now to service
            // `POST /sessions/current/flows/:id/replay`.
            server.flowReplayer = lane
            loomLane = lane
            let boundPort = lane.port
            if options.proxyInstallCa, let caDirectory = options.proxyCaDirectory {
                try installCA(derPath: caDirectory.appendingPathComponent("reticle-ca.cer").path)
            }
            if options.proxyPhoneOnboard {
                let info = try lane.startPhoneOnboarding()
                let qrPath = DaemonDiscovery.reticleHome().appendingPathComponent("phone-onboard-qr.png")
                try? info.qrPNG.write(to: qrPath)
                print("reticle serve: phone onboarding — scan the QR (or open the URL) on the device:")
                print("  url:       \(info.url)")
                print("  proxy:     \(info.proxyAddress)")
                print("  ca sha256: \(info.fingerprint)")
                print("  qr:        \(qrPath.path)")
            }
            if options.proxyDevice {
                // iOS routing is manual (a simulator/real device has no per-app
                // proxy hook — it rides the host network / Wi-Fi settings), so we
                // print the exact commands instead of mutating the host proxy.
                if options.target == "ios" {
                    printIosProxyRoutingHint(port: boundPort)
                } else {
                    reconcileStaleDeviceProxy()
                    proxyRestore = try configureDeviceProxy(port: boundPort)
                }
            }
        }

        let info = DaemonInfo(
            pid: getpid(),
            port: server.port,
            session: options.session,
            startedAt: currentMillis()
        )
        try options.discovery.write(info)
        installSignalHandlers()

        print("reticle serve: session \(options.session)")
        print("reticle serve: http://127.0.0.1:\(server.port)")
        if options.helperBroker {
            print("reticle serve: helper broker enabled")
        }
        if let boundProxyPort = loomLane?.port {
            print("reticle serve: proxy http://127.0.0.1:\(boundProxyPort)")
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
        loomLane?.stop()
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
        let previous = result["previous"] as? String
        // Persist the fact that we set the proxy so a hard-killed/crashed daemon
        // can be reconciled on the next start (SIGKILL can't run the restore).
        DeviceProxyState(pid: getpid(), serial: options.serial, proxyPort: port, previous: previous).write()
        return DeviceProxyRestore(previous: previous, proxyPort: port, helper: helper, serial: options.serial)
    }

    /// Clears a device proxy left behind by a prior daemon that died without
    /// restoring (crash / SIGKILL), so this device isn't stranded on a dead port.
    private func reconcileStaleDeviceProxy() {
        guard let stale = DeviceProxyState.readStale(serial: options.serial),
              let helper = options.helper else { return }
        let client = HelperClient(
            launcher: helper,
            javaHome: ProcessInfo.processInfo.environment["JAVA_HOME"],
            serial: stale.serial
        )
        do {
            try client.start()
            _ = try client.call("proxyClear", ["port": stale.proxyPort])
            if let previous = stale.previous, !previous.isEmpty {
                _ = try client.call("proxySet", ["value": previous])
            }
            print("reticle serve: cleared a stale device proxy left by daemon pid \(stale.pid)")
        } catch {
            FileHandle.standardError.write(Data("warning: could not clear stale device proxy: \(error)\n".utf8))
        }
        client.shutdown()
        DeviceProxyState.clear(serial: options.serial)
    }

    private func installCA(derPath: String) throws {
        // iOS: trust the MITM CA in the booted simulator's keychain — a host-side,
        // simulator-scoped action (no adb helper, no hook). The real-device
        // analogue is installing the CA as a trusted configuration profile.
        if options.target == "ios" {
            // A non-loopback bind means a real device, where the CA can't be
            // trusted from the host (`simctl keychain` is simulator-only) — it is
            // installed + trusted manually as a profile (the routing hint spells
            // out the steps). Only auto-trust when targeting the simulator.
            let isLoopback = options.proxyBind == "127.0.0.1" || options.proxyBind == "localhost" || options.proxyBind == "::1"
            guard isLoopback else {
                print("reticle serve: --proxy-install-ca is simulator-only; on a real device install")
                print("  the CA as a trusted profile (see the routing steps above)")
                return
            }
            let udid = try Simctl.resolveUdid(options.serial)
            let r = try Simctl.run(["keychain", udid, "add-root-cert", derPath])
            if r.code != 0 {
                throw HelperError("could not trust the MITM CA in simulator \(udid): "
                    + (r.err.isEmpty ? r.out : r.err))
            }
            print("reticle serve: trusted MITM CA in simulator \(udid)")
            return
        }
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
            "path": derPath,
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
            // Restored cleanly — drop the crash-recovery marker.
            DeviceProxyState.clear(serial: restore.serial)
        } catch {
            FileHandle.standardError.write(Data("warning: could not restore device proxy: \(error)\n".utf8))
        }
        client.shutdown()
    }

    /// Print the exact steps to route an iOS target through this proxy and to
    /// undo them. We never mutate the routing ourselves — the simulator path is a
    /// host-wide system-proxy setting and the device path is manual on the phone;
    /// both have a blast radius (and can strand a device if the daemon dies) that
    /// is the user's to accept and revert. The instructions branch on the proxy
    /// bind interface: loopback = simulator (shares the host network), otherwise a
    /// real device reaching the Mac over the LAN.
    private func printIosProxyRoutingHint(port: Int) {
        let bind = options.proxyBind
        let caDER = options.proxyCaDirectory?.appendingPathComponent("reticle-ca.cer")
        let isLoopback = bind == "127.0.0.1" || bind == "localhost" || bind == "::1"
        if isLoopback {
            let svc = activeNetworkService() ?? "Wi-Fi"
            print("reticle serve: iOS SIMULATOR routing is manual — the simulator shares the")
            print("  host network and has no per-app proxy hook. Route the host through this proxy:")
            print("    networksetup -setwebproxy \"\(svc)\" 127.0.0.1 \(port)")
            print("    networksetup -setsecurewebproxy \"\(svc)\" 127.0.0.1 \(port)")
            print("  Restore when done (or if this daemon exits):")
            print("    networksetup -setwebproxystate \"\(svc)\" off")
            print("    networksetup -setsecurewebproxystate \"\(svc)\" off")
            if !options.proxyInstallCa, let caDER {
                print("  For HTTPS decryption, trust the CA in the sim (or pass --proxy-install-ca):")
                print("    xcrun simctl keychain <booted-udid> add-root-cert \(caDER.path)")
            }
            print("  (For a REAL device, start with --proxy-bind 0.0.0.0 so the phone can reach")
            print("   the Mac over the LAN; the hint then prints the device-side steps.)")
        } else {
            let ip = (bind == "0.0.0.0" || bind == "::") ? (hostLanIP() ?? "<mac-lan-ip>") : bind
            print("reticle serve: iOS DEVICE routing is manual — set it on the phone (both device")
            print("  and Mac must be on the same Wi-Fi). On the iPhone:")
            print("    Settings > Wi-Fi > (your network) > Configure Proxy > Manual")
            print("      Server \(ip)   Port \(port)")
            print("  Undo by switching Configure Proxy back to Off when done.")
            print("  For HTTPS decryption, install + trust the CA on the device:")
            if let caDER {
                print("    1) get the CA onto the phone (AirDrop \(caDER.path), or serve it and open in Safari)")
            } else {
                print("    1) enable MITM (--proxy-mitm) so a CA is issued, then get its .cer onto the phone")
            }
            print("    2) Settings > General > VPN & Device Management > install the profile")
            print("    3) Settings > General > About > Certificate Trust Settings > enable full trust")
            print("  NOTE: --proxy-bind \(bind) exposes the MITM proxy on your LAN for the run.")
        }
        fflush(stdout)
    }

    private func runReadOnly(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The default-route interface (e.g. `en0`), used by both the service-name and
    /// LAN-IP lookups.
    private func defaultInterface() -> String? {
        guard let route = runReadOnly("/sbin/route", ["get", "default"]),
              let line = route.split(separator: "\n").first(where: { $0.contains("interface:") }) else { return nil }
        return line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
    }

    /// The Mac's IPv4 on the default route, for the device's Wi-Fi proxy server field.
    private func hostLanIP() -> String? {
        guard let iface = defaultInterface(),
              let ip = runReadOnly("/usr/sbin/ipconfig", ["getifaddr", iface])?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !ip.isEmpty else { return nil }
        return ip
    }

    /// Best-effort name of the network service on the default route (e.g. "Wi-Fi"),
    /// so the printed `networksetup` commands are copy-paste ready. Falls back to
    /// nil when it can't be determined.
    private func activeNetworkService() -> String? {
        guard let iface = defaultInterface(),
              let order = runReadOnly("/usr/sbin/networksetup", ["-listnetworkserviceorder"]) else { return nil }
        // Each service is a "(N) Name" line followed by a "(Hardware Port: ..., Device: enX)" line.
        let lines = order.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (i, line) in lines.enumerated() where line.contains("Device: \(iface))") && i > 0 {
            if let sep = lines[i - 1].range(of: ") ") {
                return String(lines[i - 1][sep.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func installSignalHandlers() {
        // SIGHUP catches the common "closed the terminal that ran serve" case,
        // which otherwise skipped restore and stranded the device on a dead proxy.
        let signals = [SIGINT, SIGTERM, SIGHUP, SIGQUIT]
        for sig in signals { signal(sig, SIG_IGN) }
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
