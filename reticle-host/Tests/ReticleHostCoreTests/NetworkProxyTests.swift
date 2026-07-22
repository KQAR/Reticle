import Darwin
import Dispatch
import Foundation
import Testing
@testable import ReticleHostCore
@testable import ReticleNetworkLane

@Suite("Network proxy", .serialized)
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
        // Streaming emits the terminal response event when the upstream stream
        // finishes, which can land just after the client has already read the
        // full content-length body — so wait for it rather than assuming it is
        // synchronous with the client's last byte.
        #expect(waitForEvent(in: store) { $0.type == "network.response" })
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

    /// Polls the event store until `predicate` matches an event or the timeout
    /// elapses. The streamed proxy emits its terminal event on URLSession's
    /// completion callback, so a consumer may briefly observe the client's
    /// response before the matching event is recorded.
    private func waitForEvent(
        in store: EventStore,
        timeoutSeconds: Double = 2,
        _ predicate: (ReticleEventEnvelope) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if store.events().contains(where: predicate) { return true }
            usleep(5_000)
        }
        return store.events().contains(where: predicate)
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
        #expect(waitForEvent(in: store) { $0.type == "network.response" })
        #expect(store.events().filter { $0.type == "network.response" }.last?.payload["mocked"] == nil)
    }

    @Test func oversizedRequestBodyIsRejectedWith413AndAnErrorEvent() throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "proxy", rootDirectory: root, limit: 20)
        let upstream = try ReticleHttpServer(store: store, port: 0)
        try upstream.start()
        defer { upstream.stop() }

        // Cap at 16 bytes; send 64 so the very first body chunk trips it.
        let proxy = try NetworkProxyServer(
            store: store,
            configuration: NetworkProxyConfiguration(port: 0, target: "android:test", maxRequestBodyBytes: 16)
        )
        try proxy.start()
        defer { proxy.stop() }

        let payload = String(repeating: "x", count: 64)
        let response = try readSocket(
            port: proxy.port,
            request: "POST http://127.0.0.1:\(upstream.port)/echo HTTP/1.1\r\nHost: 127.0.0.1:\(upstream.port)\r\nContent-Length: \(payload.count)\r\n\r\n\(payload)"
        )

        #expect(response.contains("413"))
        #expect(waitForEvent(in: store) { $0.type == "network.error" })
        let error = store.events().first { $0.type == "network.error" }
        if case .string(let message)? = error?.payload["error"] {
            #expect(message.contains("413"))
        } else {
            Issue.record("missing 413 error message")
        }
    }

    @Test func slowUpstreamDoesNotBlockMockedRequests() throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "proxy", rootDirectory: root, limit: 20)
        let upstream = try HangingHTTPServer(delaySeconds: 5)
        defer { upstream.stop() }

        let mockStore = try NetworkMockStore(sessionDirectory: store.sessionDirectory)
        _ = try mockStore.upsertValue(NetworkMockValueRequest(id: "fast", status: 201, headers: ["X-Mock": "yes"], body: #"{"ok":true}"#, contentType: "application/json"))
        _ = try mockStore.upsertRule(NetworkMockRuleRequest(id: "fast", enabled: true, priority: 100, method: "GET", url: "/fast", match: .exact, valueId: "fast"))

        let proxy = try NetworkProxyServer(
            store: store,
            configuration: NetworkProxyConfiguration(port: 0, target: "android:test", upstreamTimeoutSeconds: 10),
            mockStore: mockStore
        )
        try proxy.start()
        defer { proxy.stop() }

        let slowDone = DispatchSemaphore(value: 0)
        let slowThread = Thread {
            _ = try? readSocket(
                port: proxy.port,
                request: "GET http://127.0.0.1:\(upstream.port)/slow HTTP/1.1\r\nHost: 127.0.0.1:\(upstream.port)\r\n\r\n",
                timeoutSeconds: 10
            )
            slowDone.signal()
        }
        slowThread.start()
        #expect(upstream.accepted.wait(timeout: .now() + 2) == .success)

        let start = Date()
        let response = try readSocket(
            port: proxy.port,
            request: "GET http://mock.test/fast HTTP/1.1\r\nHost: mock.test\r\n\r\n"
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(response.contains("201 Created"))
        #expect(response.contains(#"{"ok":true}"#))
        #expect(elapsed < 1)
        #expect(slowDone.wait(timeout: .now() + 0.1) == .timedOut)
        upstream.stop()
        #expect(slowDone.wait(timeout: .now() + 2) == .success)
    }

    @Test func streamsFullBodyToClientWhileTruncatingStoredArtifact() throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "proxy", rootDirectory: root, limit: 20)
        let bodyBytes = 200 * 1024
        let upstream = try LargeBodyHTTPServer(bodyBytes: bodyBytes)
        defer { upstream.stop() }

        let limit = 64 * 1024
        let proxy = try NetworkProxyServer(
            store: store,
            configuration: NetworkProxyConfiguration(port: 0, target: "android:test", bodyLimitBytes: limit)
        )
        try proxy.start()
        defer { proxy.stop() }

        let response = try readSocket(
            port: proxy.port,
            request: "GET http://127.0.0.1:\(upstream.port)/big HTTP/1.1\r\nHost: 127.0.0.1:\(upstream.port)\r\n\r\n",
            timeoutSeconds: 5
        )

        // The client receives the whole body even though we only keep a bounded
        // prefix as an artifact.
        #expect(response.contains("200 OK"))
        if let headerEnd = response.range(of: "\r\n\r\n") {
            #expect(response.distance(from: headerEnd.upperBound, to: response.endIndex) == bodyBytes)
        } else {
            Issue.record("no header terminator in response")
        }

        #expect(waitForEvent(in: store) { $0.type == "network.response" })
        let responseEvent = store.events().last { $0.type == "network.response" }
        #expect(responseEvent?.payload["responseBodyBytes"] == .number(Double(bodyBytes)))
        #expect(responseEvent?.payload["responseBodyTruncated"] == .bool(true))

        // The stored artifact is capped at the configured limit, not the full body.
        let ref = responseEvent?.refs.first { $0.key.hasPrefix("responseBody.") }
        #expect(ref != nil)
        if let path = ref?.value {
            let stored = try Data(contentsOf: URL(fileURLWithPath: path))
            #expect(stored.count == limit)
        }
    }

    @Test func proxyDoesNotForwardHopByHopHeaders() throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "proxy", rootDirectory: root, limit: 20)
        let upstream = try RecordingHTTPServer(responseHeaders: [
            "Connection": "X-Response-Secret, close",
            "X-Response-Secret": "drop",
            "X-Response-Keep": "yes",
            "Proxy-Authenticate": "drop"
        ])
        defer { upstream.stop() }

        let proxy = try NetworkProxyServer(
            store: store,
            configuration: NetworkProxyConfiguration(port: 0, target: "android:test")
        )
        try proxy.start()
        defer { proxy.stop() }

        let response = try readSocket(
            port: proxy.port,
            request: "GET http://127.0.0.1:\(upstream.port)/headers HTTP/1.1\r\n"
                + "Host: 127.0.0.1:\(upstream.port)\r\n"
                + "Connection: X-Request-Secret, keep-alive\r\n"
                + "X-Request-Secret: drop\r\n"
                + "Proxy-Connection: keep-alive\r\n"
                + "X-Request-Keep: yes\r\n"
                + "\r\n"
        )
        let rawUpstreamRequest = try upstream.waitForRequest()

        #expect(rawUpstreamRequest.contains("X-Request-Keep: yes"))
        #expect(!rawUpstreamRequest.contains("X-Request-Secret"))
        #expect(!rawUpstreamRequest.contains("Proxy-Connection"))
        #expect(response.contains("X-Response-Keep: yes"))
        #expect(!response.contains("X-Response-Secret"))
        #expect(!response.contains("Proxy-Authenticate"))
        #expect(!response.contains("Connection:"))
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

    @Test func mockStoreMatchesOptionalHostAndQueryPredicates() throws {
        let root = try temporaryDirectory()
        let session = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let store = try NetworkMockStore(sessionDirectory: session)
        _ = try store.upsertValue(NetworkMockValueRequest(id: "filtered", status: 200, headers: [:], body: "filtered", contentType: nil))
        _ = try store.upsertRule(NetworkMockRuleRequest(
            id: "filtered",
            enabled: true,
            priority: 10,
            method: "GET",
            url: "/api/search",
            match: .exact,
            host: "*.example.test",
            query: ["page": "1", "kind": "user"],
            valueId: "filtered"
        ))

        let matched = try store.resolve(NetworkMockRequest(
            method: "GET",
            url: "http://api.example.test/api/search?page=1&kind=user&extra=yes",
            path: "/api/search?page=1&kind=user&extra=yes"
        ))
        let wrongHost = try store.resolve(NetworkMockRequest(
            method: "GET",
            url: "http://example.test/api/search?page=1&kind=user",
            path: "/api/search?page=1&kind=user"
        ))
        let wrongQuery = try store.resolve(NetworkMockRequest(
            method: "GET",
            url: "http://api.example.test/api/search?page=2&kind=user",
            path: "/api/search?page=2&kind=user"
        ))

        #expect(matched?.value.id == "filtered")
        #expect(wrongHost == nil)
        #expect(wrongQuery == nil)
    }

    @Test func mockStoreSupportsRegexAnyMethodAndQueryWildcard() throws {
        let root = try temporaryDirectory()
        let session = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let store = try NetworkMockStore(sessionDirectory: session)
        _ = try store.upsertValue(NetworkMockValueRequest(id: "v", status: 200, headers: [:], body: "ok", contentType: nil))

        // regex on the path, ANY method, and a presence-only query predicate.
        _ = try store.upsertRule(NetworkMockRuleRequest(
            id: "regex",
            enabled: true,
            priority: 10,
            method: "ANY",
            url: #"^/api/users/\d+$"#,
            match: .regex,
            query: ["token": "*"],
            valueId: "v"
        ))

        // Any method matches, the numeric id matches the pattern, token present.
        #expect(try store.resolve(NetworkMockRequest(method: "GET", url: "http://a.test/api/users/42?token=abc", path: "/api/users/42?token=abc"))?.value.id == "v")
        #expect(try store.resolve(NetworkMockRequest(method: "DELETE", url: "http://a.test/api/users/7?token=z", path: "/api/users/7?token=z"))?.value.id == "v")
        // Non-numeric id fails the regex.
        #expect(try store.resolve(NetworkMockRequest(method: "GET", url: "http://a.test/api/users/me?token=abc", path: "/api/users/me?token=abc")) == nil)
        // Missing the required query key fails even though the path matches.
        #expect(try store.resolve(NetworkMockRequest(method: "GET", url: "http://a.test/api/users/42", path: "/api/users/42")) == nil)

        // An invalid regex is rejected at upsert rather than failing silently later.
        #expect(throws: NetworkMockError.self) {
            _ = try store.upsertRule(NetworkMockRuleRequest(id: "bad", enabled: true, priority: 1, method: "GET", url: "([", match: .regex, valueId: "v"))
        }
    }

    @Test func mockStoreExportImportPreservesBinaryBodies() throws {
        let root = try temporaryDirectory()
        let firstSession = root.appendingPathComponent("first", isDirectory: true)
        let secondSession = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstSession, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondSession, withIntermediateDirectories: true)
        let binary = Data([0, 1, 2, 0xff])
        let first = try NetworkMockStore(sessionDirectory: firstSession)
        _ = try first.upsertValue(NetworkMockValueRequest(
            id: "bin",
            status: 206,
            headers: ["Content-Type": "application/octet-stream"],
            body: nil,
            bodyBase64: binary.base64EncodedString(),
            contentType: nil
        ))
        _ = try first.upsertRule(NetworkMockRuleRequest(id: "bin", enabled: true, priority: 1, method: "GET", url: "/bin", match: .exact, valueId: "bin"))

        let second = try NetworkMockStore(sessionDirectory: secondSession)
        try second.importPackage(try first.exportPackage())
        let result = try second.resolve(NetworkMockRequest(method: "GET", url: "http://example.test/bin", path: "/bin"))

        #expect(result?.value.status == 206)
        #expect(result?.body == binary)
        try second.clear()
        #expect(second.listRules().isEmpty)
        #expect(second.listValues().isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func readSocket(port: Int, request: String, timeoutSeconds: Int = 1) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NetworkProxyTestFailure.socket }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
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
            if responseComplete(data) { break }
        }
        close(fd)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func responseComplete(_ data: Data) -> Bool {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        guard let headers = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return false }
        let contentLength = headers
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") }
        guard let contentLength else { return false }
        let bodyStart = headerEnd.upperBound
        return data.count - bodyStart >= contentLength
    }
}

private enum NetworkProxyTestFailure: Error {
    case socket
    case timedOut
    case utf8
}

private final class HangingHTTPServer: @unchecked Sendable {
    let accepted = DispatchSemaphore(value: 0)
    let port: Int

    private let fd: Int32
    private let delaySeconds: UInt32
    private let lock = NSLock()
    private var stopped = false
    private var connections: [Int32] = []

    init(delaySeconds: UInt32) throws {
        self.delaySeconds = delaySeconds
        fd = try bindLoopbackSocket()
        port = try boundPort(fd)
        listen(fd, 16)
        DispatchQueue.global().async { [self] in acceptLoop() }
    }

    func stop() {
        let (shouldClose, active) = lock.withLock { () -> (Bool, [Int32]) in
            guard !stopped else { return (false, []) }
            stopped = true
            return (true, connections)
        }
        guard shouldClose else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        for connection in active {
            shutdown(connection, SHUT_RDWR)
            close(connection)
        }
    }

    private func acceptLoop() {
        while true {
            let connection = accept(fd, nil, nil)
            if connection < 0 { return }
            lock.withLock {
                connections.append(connection)
            }
            accepted.signal()
            sleep(delaySeconds)
            shutdown(connection, SHUT_RDWR)
            close(connection)
            lock.withLock {
                connections.removeAll { $0 == connection }
            }
            if lock.withLock({ stopped }) { return }
        }
    }
}

private final class RecordingHTTPServer: @unchecked Sendable {
    let port: Int

    private let fd: Int32
    private let responseHeaders: [String: String]
    private let requestReady = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var request: String?

    init(responseHeaders: [String: String]) throws {
        self.responseHeaders = responseHeaders
        fd = try bindLoopbackSocket()
        port = try boundPort(fd)
        listen(fd, 1)
        DispatchQueue.global().async { [self] in acceptOnce() }
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    func waitForRequest() throws -> String {
        guard requestReady.wait(timeout: .now() + 2) == .success else {
            throw NetworkProxyTestFailure.timedOut
        }
        return lock.withLock { request ?? "" }
    }

    private func acceptOnce() {
        let connection = accept(fd, nil, nil)
        if connection < 0 { return }
        defer {
            shutdown(connection, SHUT_RDWR)
            close(connection)
        }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(connection, &buf, buf.count, 0)
            if n <= 0 { break }
            data.append(contentsOf: buf.prefix(n))
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        lock.withLock {
            request = String(data: data, encoding: .utf8)
        }
        requestReady.signal()
        var response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n"
        for (name, value) in responseHeaders {
            response += "\(name): \(value)\r\n"
        }
        response += "\r\nok"
        _ = response.withCString { ptr in send(connection, ptr, strlen(ptr), 0) }
    }
}

/// Serves one identity response of `bodyBytes` 'A' characters with a
/// Content-Length header, so the proxy takes the content-length streaming path.
private final class LargeBodyHTTPServer: @unchecked Sendable {
    let port: Int

    private let fd: Int32
    private let bodyBytes: Int

    init(bodyBytes: Int) throws {
        self.bodyBytes = bodyBytes
        fd = try bindLoopbackSocket()
        port = try boundPort(fd)
        listen(fd, 4)
        DispatchQueue.global().async { [self] in acceptOnce() }
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    private func acceptOnce() {
        let connection = accept(fd, nil, nil)
        if connection < 0 { return }
        defer {
            shutdown(connection, SHUT_RDWR)
            close(connection)
        }
        var request = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(connection, &buf, buf.count, 0)
            if n <= 0 { break }
            request.append(contentsOf: buf.prefix(n))
            if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        var payload = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(bodyBytes)\r\n\r\n".utf8)
        payload.append(Data(repeating: UInt8(ascii: "A"), count: bodyBytes))
        payload.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while offset < raw.count {
                let sent = send(connection, base + offset, raw.count - offset, 0)
                if sent <= 0 { break }
                offset += sent
            }
        }
    }
}

private func bindLoopbackSocket() throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw NetworkProxyTestFailure.socket }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else {
        close(fd)
        throw NetworkProxyTestFailure.socket
    }
    return fd
}

private func boundPort(_ fd: Int32) throws -> Int {
    var addr = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let result = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &length)
        }
    }
    guard result == 0 else { throw NetworkProxyTestFailure.socket }
    return Int(in_port_t(bigEndian: addr.sin_port))
}
