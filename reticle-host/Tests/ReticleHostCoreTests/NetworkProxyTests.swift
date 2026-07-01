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

    @Test func httpProxyReturnsMockResponseAndPublishesMockMetadata() throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "proxy", rootDirectory: root, limit: 20)
        let mockStore = try NetworkMockStore(sessionDirectory: store.sessionDirectory)
        _ = try mockStore.upsertValue(NetworkMockValueRequest(
            id: "ok",
            status: 201,
            headers: ["X-Mock": "yes"],
            body: #"{"mocked":true}"#,
            contentType: "application/json"
        ))
        _ = try mockStore.upsertRule(NetworkMockRuleRequest(
            id: "users",
            enabled: true,
            priority: 10,
            method: "GET",
            url: "/api/users",
            match: .exact,
            valueId: "ok"
        ))

        let proxy = try NetworkProxyServer(
            store: store,
            configuration: NetworkProxyConfiguration(port: 0, target: "android:test"),
            mockStore: mockStore
        )
        try proxy.start()
        defer { proxy.stop() }

        let response = try readSocket(
            port: proxy.port,
            request: "GET http://mock.test/api/users HTTP/1.1\r\nHost: mock.test\r\n\r\n"
        )

        #expect(response.contains("201 Created"))
        #expect(response.contains("X-Mock: yes"))
        #expect(response.contains(#"{"mocked":true}"#))
        let networkEvents = store.events().filter { $0.source == "proxy" }
        #expect(networkEvents.map(\.type) == ["network.request", "network.response"])
        #expect(networkEvents.last?.payload["mocked"] == .bool(true))
        #expect(networkEvents.last?.payload["mockRuleId"] == .string("users"))
        #expect(networkEvents.last?.payload["mockValueId"] == .string("ok"))
        #expect(networkEvents.last?.refs.keys.contains { $0.hasPrefix("responseBody.") } == true)
    }

    @Test func disabledMockFallsBackToUpstream() throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "proxy", rootDirectory: root, limit: 20)
        let upstream = try ReticleHttpServer(store: store, port: 0)
        try upstream.start()
        defer { upstream.stop() }

        let mockStore = try NetworkMockStore(sessionDirectory: store.sessionDirectory)
        _ = try mockStore.upsertValue(NetworkMockValueRequest(id: "off", status: 418, headers: [:], body: "mock", contentType: nil))
        _ = try mockStore.upsertRule(NetworkMockRuleRequest(
            id: "disabled",
            enabled: false,
            priority: 100,
            method: "GET",
            url: "/health",
            match: .exact,
            valueId: "off"
        ))
        let proxy = try NetworkProxyServer(
            store: store,
            configuration: NetworkProxyConfiguration(port: 0, target: "android:test"),
            mockStore: mockStore
        )
        try proxy.start()
        defer { proxy.stop() }

        let response = try readSocket(
            port: proxy.port,
            request: "GET http://127.0.0.1:\(upstream.port)/health HTTP/1.1\r\nHost: 127.0.0.1:\(upstream.port)\r\n\r\n"
        )

        #expect(response.contains("200 OK"))
        #expect(!response.contains("mock"))
        #expect(store.events().filter { $0.type == "network.response" }.last?.payload["mocked"] == nil)
    }

    @Test func mockStorePersistsRulesValuesAndUsesPriority() throws {
        let root = try temporaryDirectory()
        let session = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let store = try NetworkMockStore(sessionDirectory: session)
        _ = try store.upsertValue(NetworkMockValueRequest(id: "low", status: 200, headers: [:], body: "low", contentType: nil))
        _ = try store.upsertValue(NetworkMockValueRequest(id: "high", status: 202, headers: [:], body: "high", contentType: nil))
        _ = try store.upsertRule(NetworkMockRuleRequest(id: "low", enabled: true, priority: 1, method: "GET", url: "/api", match: .prefix, valueId: "low"))
        _ = try store.upsertRule(NetworkMockRuleRequest(id: "high", enabled: true, priority: 50, method: "GET", url: "/api/users", match: .prefix, valueId: "high"))

        let reloaded = try NetworkMockStore(sessionDirectory: session)
        let result = try reloaded.resolve(NetworkMockRequest(method: "GET", url: "http://example.test/api/users/1", path: "/api/users/1"))

        #expect(result?.rule.id == "high")
        #expect(result?.value.id == "high")
        #expect(String(data: result?.body ?? Data(), encoding: .utf8) == "high")
        #expect(throws: NetworkMockError.self) {
            try reloaded.removeValue(id: "high")
        }
    }

    @Test func mockValueUpdatePreservesBodyAndAffectsFutureMatches() throws {
        let root = try temporaryDirectory()
        let session = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let store = try NetworkMockStore(sessionDirectory: session)
        _ = try store.upsertValue(NetworkMockValueRequest(
            id: "shared",
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"ok":true}"#,
            contentType: nil
        ))
        _ = try store.upsertRule(NetworkMockRuleRequest(id: "first", enabled: true, priority: 10, method: "GET", url: "/api/first", match: .exact, valueId: "shared"))
        _ = try store.upsertRule(NetworkMockRuleRequest(id: "second", enabled: true, priority: 10, method: "GET", url: "/api/second", match: .exact, valueId: "shared"))

        _ = try store.upsertValue(NetworkMockValueRequest(id: "shared", status: 503, headers: nil, body: nil, contentType: nil))
        let first = try store.resolve(NetworkMockRequest(method: "GET", url: "http://example.test/api/first", path: "/api/first"))
        let second = try store.resolve(NetworkMockRequest(method: "GET", url: "http://example.test/api/second", path: "/api/second"))

        #expect(first?.value.status == 503)
        #expect(second?.value.status == 503)
        #expect(String(data: first?.body ?? Data(), encoding: .utf8) == #"{"ok":true}"#)
        #expect(first?.value.headers["Content-Type"] == "application/json")
    }

    @Test func mockStoreMatchesFullUrlAndPathExact() throws {
        let root = try temporaryDirectory()
        let session = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let store = try NetworkMockStore(sessionDirectory: session)
        _ = try store.upsertValue(NetworkMockValueRequest(id: "full", status: 200, headers: [:], body: "full", contentType: nil))
        _ = try store.upsertValue(NetworkMockValueRequest(id: "path", status: 200, headers: [:], body: "path", contentType: nil))
        _ = try store.upsertRule(NetworkMockRuleRequest(id: "full", enabled: true, priority: 10, method: "POST", url: "http://example.test/api/full", match: .exact, valueId: "full"))
        _ = try store.upsertRule(NetworkMockRuleRequest(id: "path", enabled: true, priority: 10, method: "GET", url: "/api/path", match: .exact, valueId: "path"))

        #expect(try store.resolve(NetworkMockRequest(method: "POST", url: "http://example.test/api/full", path: "/api/full"))?.value.id == "full")
        #expect(try store.resolve(NetworkMockRequest(method: "GET", url: "http://other.test/api/path", path: "/api/path"))?.value.id == "path")
        #expect(try store.resolve(NetworkMockRequest(method: "DELETE", url: "http://example.test/api/full", path: "/api/full")) == nil)
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
