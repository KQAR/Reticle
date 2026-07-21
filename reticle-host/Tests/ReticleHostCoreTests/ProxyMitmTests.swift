import Darwin
import Dispatch
import Foundation
import NIOSSL
import Testing
import X509
@testable import ReticleHostCore
@testable import ReticleNetworkLane

/// Coverage for the previously-untested TLS-interception surface: the host
/// policy gate, the certificate store (CA + leaf issuance/caching), the CONNECT
/// tunnel round-trip, and the upstream-failure error event. This is the
/// regression floor the proxy event-loop refactor needs before it can move the
/// blocking work (body writes, cert generation) off the loop with confidence.
@Suite("Proxy MITM", .serialized)
struct ProxyMitmTests {

    // MARK: TlsInterceptionPolicy

    @Test func policyOnlyAllowsWhenEnabledAndMatched() {
        let disabled = TlsInterceptionPolicy(enabled: false, allowlist: ["example.com"])
        #expect(disabled.allows(host: "example.com") == false)

        let exact = TlsInterceptionPolicy(enabled: true, allowlist: ["example.com"])
        #expect(exact.allows(host: "example.com"))
        #expect(exact.allows(host: "EXAMPLE.COM"))          // case-insensitive
        #expect(exact.allows(host: "other.com") == false)
        #expect(exact.allows(host: "sub.example.com") == false)

        let wildcard = TlsInterceptionPolicy(enabled: true, allowlist: ["*.example.com"])
        #expect(wildcard.allows(host: "api.example.com"))
        #expect(wildcard.allows(host: "API.Example.com"))
        #expect(wildcard.allows(host: "example.com") == false) // bare apex isn't a *. match
        #expect(wildcard.allows(host: "example.com.evil.com") == false)
    }

    // MARK: ProxyCertificateStore

    @Test func certificateStoreGeneratesCAOnceAndCachesContexts() throws {
        let dir = try temporaryDirectory()
        let store = ProxyCertificateStore(directory: dir)
        try store.validate()

        for url in [store.caCertificateDER, store.caCertificatePEM] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        // Idempotent: a second validate() must not rewrite the CA (the on-disk
        // material — and any client that trusted it — has to stay stable).
        let before = try Data(contentsOf: store.caCertificateDER)
        try store.validate()
        #expect(try Data(contentsOf: store.caCertificateDER) == before)

        // serverContext caches per host: the first CONNECT generates a leaf, and
        // every later CONNECT to the same host reuses the same NIOSSLContext.
        let first = try store.serverContext(host: "example.com")
        let second = try store.serverContext(host: "example.com")
        #expect(first === second)
        let other = try store.serverContext(host: "other.com")
        #expect(first !== other)
    }

    @Test func leafCertificateIsSignedByCAAndCarriesHostSAN() throws {
        let dir = try temporaryDirectory()
        let store = ProxyCertificateStore(directory: dir)
        _ = try store.serverContext(host: "api.example.com")

        let caPEM = try String(contentsOf: store.caCertificatePEM, encoding: .utf8)
        let ca = try Certificate(pemEncoded: caPEM)

        let leafURL = dir.appendingPathComponent("leaf/api.example.com.pem")
        let leaf = try Certificate(pemEncoded: try String(contentsOf: leafURL, encoding: .utf8))

        // Chain integrity: the leaf must be issued by the Reticle CA...
        #expect(leaf.issuer == ca.subject)
        #expect(leaf.subject != ca.subject)
        // ...and present the host as a DNS SAN so a client validates the name.
        let san = try leaf.extensions.subjectAlternativeNames
        let dnsNames: [String] = (san ?? SubjectAlternativeNames([])).compactMap {
            if case .dnsName(let name) = $0 { return name }
            return nil
        }
        #expect(dnsNames.contains("api.example.com"))
    }

    @Test func leafForIPHostUsesIPSAN() throws {
        let dir = try temporaryDirectory()
        let store = ProxyCertificateStore(directory: dir)
        _ = try store.serverContext(host: "10.0.0.5")

        let leafURL = dir.appendingPathComponent("leaf/10.0.0.5.pem")
        let leaf = try Certificate(pemEncoded: try String(contentsOf: leafURL, encoding: .utf8))
        let san = try leaf.extensions.subjectAlternativeNames
        let hasIP = (san ?? SubjectAlternativeNames([])).contains {
            if case .ipAddress = $0 { return true }
            return false
        }
        #expect(hasIP)
    }

    // MARK: CONNECT tunnel

    @Test func connectTunnelForwardsBytesToPlaintextUpstream() throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "proxy", rootDirectory: root, limit: 20)
        let upstream = try ReticleHttpServer(store: store, port: 0)
        try upstream.start()
        defer { upstream.stop() }

        // No MITM allowlist → CONNECT to the upstream is a plain byte tunnel.
        let proxy = try NetworkProxyServer(
            store: store,
            configuration: NetworkProxyConfiguration(port: 0, target: "android:test")
        )
        try proxy.start()
        defer { proxy.stop() }

        let response = try connectThenRequest(
            proxyPort: proxy.port,
            connectTarget: "127.0.0.1:\(upstream.port)",
            tunneledRequest: "GET /health HTTP/1.1\r\nHost: 127.0.0.1:\(upstream.port)\r\nConnection: close\r\n\r\n"
        )
        #expect(response.contains("200 OK"))

        let connectEvents = store.events().filter { $0.source == "proxy" && $0.payload["method"] == .string("CONNECT") }
        #expect(connectEvents.map(\.type).contains("network.request"))
        #expect(connectEvents.first?.payload["tunnel"] == .bool(true))
    }

    // MARK: Upstream failure

    @Test func upstreamFailureEmitsErrorEventPreservingMethod() throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "proxy", rootDirectory: root, limit: 20)

        // A port with nothing listening: the upstream fetch fails.
        let deadPort = try reserveClosedPort()
        let proxy = try NetworkProxyServer(
            store: store,
            configuration: NetworkProxyConfiguration(port: 0, target: "android:test")
        )
        try proxy.start()
        defer { proxy.stop() }

        let response = try readOneShot(
            port: proxy.port,
            request: "GET http://127.0.0.1:\(deadPort)/x HTTP/1.1\r\nHost: 127.0.0.1:\(deadPort)\r\nConnection: close\r\n\r\n"
        )
        #expect(response.contains("502"))

        let errors = store.events().filter { $0.source == "proxy" && $0.type == "network.error" }
        #expect(errors.isEmpty == false)
        // Regression guard: the plaintext path used to rebuild the error payload
        // with method "UNKNOWN", dropping the real method. It must be GET now.
        #expect(errors.last?.payload["method"] == .string("GET"))
        #expect(errors.last?.payload["method"] != .string("UNKNOWN"))
    }

    // MARK: helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Binds a loopback socket, reads its port, then closes it — the port is now
    /// free and (briefly) has nothing listening, so a connect there refuses.
    private func reserveClosedPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyMitmTestFailure.socket }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { close(fd); throw ProxyMitmTestFailure.socket }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { close(fd); throw ProxyMitmTestFailure.socket }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        close(fd)
        return port
    }

    private func openSocket(port: Int, timeoutSeconds: Int = 2) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ProxyMitmTestFailure.socket }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { close(fd); throw ProxyMitmTestFailure.socket }
        return fd
    }

    private func send(_ fd: Int32, _ s: String) {
        _ = s.withCString { Darwin.send(fd, $0, strlen($0), 0) }
    }

    private func recvUntilHeaderEnd(_ fd: Int32) -> Data {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buf.prefix(n))
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        return data
    }

    private func recvAll(_ fd: Int32) -> Data {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buf.prefix(n))
        }
        return data
    }

    private func readOneShot(port: Int, request: String) throws -> String {
        let fd = try openSocket(port: port)
        defer { close(fd) }
        send(fd, request)
        return String(data: recvAll(fd), encoding: .utf8) ?? ""
    }

    private func connectThenRequest(proxyPort: Int, connectTarget: String, tunneledRequest: String) throws -> String {
        let fd = try openSocket(port: proxyPort)
        defer { close(fd) }
        send(fd, "CONNECT \(connectTarget) HTTP/1.1\r\nHost: \(connectTarget)\r\n\r\n")
        let established = String(data: recvUntilHeaderEnd(fd), encoding: .utf8) ?? ""
        guard established.contains("200") else { throw ProxyMitmTestFailure.connectRejected(established) }
        send(fd, tunneledRequest)
        return String(data: recvAll(fd), encoding: .utf8) ?? ""
    }
}

private enum ProxyMitmTestFailure: Error {
    case socket
    case connectRejected(String)
}
