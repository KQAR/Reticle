import Darwin
import Foundation
import Testing
@testable import ReticleHostCore

@Suite("Network proxy")
struct NetworkProxyTests {
    @Test func httpProxyForwardsRequestAndPublishesEvents() throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "proxy", rootDirectory: root, limit: 20)
        let upstream = try ReticleHttpServer(store: store, port: 0)
        try upstream.start()
        defer { upstream.stop() }

        let proxy = try NetworkProxyServer(
            store: store,
            configuration: NetworkProxyConfiguration(port: 0, target: "android:test")
        )
        try proxy.start()
        defer { proxy.stop() }

        let response = try readSocket(
            port: proxy.port,
            request: "GET http://127.0.0.1:\(upstream.port)/health HTTP/1.1\r\nHost: 127.0.0.1:\(upstream.port)\r\nX-Reticle-Test: visible\r\n\r\n"
        )

        #expect(response.contains("200 OK"))
        let networkEvents = store.events().filter { $0.source == "proxy" }
        #expect(networkEvents.map(\.type).contains("network.request"))
        #expect(networkEvents.map(\.type).contains("network.response"))
        #expect(networkEvents.last?.payload["status"] == .number(200))
        #expect(networkEvents.first?.payload["requestHeaders"] == .object([
            "Host": .string("127.0.0.1:\(upstream.port)"),
            "X-Reticle-Test": .string("visible")
        ]))
        if case .object(let headers) = networkEvents.last?.payload["responseHeaders"] {
            #expect(headers["Content-Length"] != nil)
        } else {
            Issue.record("missing response headers")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readSocket(port: Int, request: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NetworkProxyTestFailure.socket }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { close(fd); throw NetworkProxyTestFailure.socket }
        _ = request.withCString { ptr in send(fd, ptr, strlen(ptr), 0) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buf.prefix(n))
        }
        close(fd)
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private enum NetworkProxyTestFailure: Error {
    case socket
}
