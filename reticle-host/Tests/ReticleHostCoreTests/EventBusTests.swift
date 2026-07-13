import Darwin
import Foundation
import Testing
@testable import ReticleHostCore

@Suite("Reticle event bus", .serialized)
struct EventBusTests {
    @Test func eventStoreAppendsQueriesAndReplaysJsonl() throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "test", rootDirectory: root, limit: 2)

        let first = try store.append(EventPostRequest(source: "ui", type: "ui.snapshot"))
        let second = try store.append(EventPostRequest(source: "action", type: "action.trace"))
        let third = try store.append(EventPostRequest(source: "log", type: "log"))

        #expect(store.events().map(\.id) == [second.id, third.id])
        #expect(store.events(since: first.id).map(\.type) == ["action.trace", "log"])

        let replayed = try EventStore(session: "test", rootDirectory: root, limit: 10)
        #expect(replayed.events().map(\.type) == ["ui.snapshot", "action.trace", "log"])
    }

    @Test func eventStoreSkipsCorruptOrPartialTrailingLine() throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "test", rootDirectory: root, limit: 10)
        _ = try store.append(EventPostRequest(source: "ui", type: "ui.snapshot"))
        _ = try store.append(EventPostRequest(source: "action", type: "action.trace"))

        // Simulate a crash mid-append: a torn/partial JSON line with no newline.
        let handle = try FileHandle(forWritingTo: store.eventsFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"evt_000000000000".utf8))
        try handle.close()

        // Reopening must not throw and must recover the two valid events.
        let reopened = try EventStore(session: "test", rootDirectory: root, limit: 10)
        #expect(reopened.events().map(\.type) == ["ui.snapshot", "action.trace"])

        // And a fresh append after recovery must get the next sequence id, not
        // collide with the salvaged events.
        let next = try reopened.append(EventPostRequest(source: "log", type: "log"))
        #expect(next.id == "evt_0000000000000003")
    }

    @Test func daemonDiscoveryResolvesAutomaticTraceDirectory() throws {
        let root = try temporaryDirectory()
        let discovery = DaemonDiscovery(fileURL: root.appendingPathComponent("daemon.json"))
        let info = DaemonInfo(pid: getpid(), port: 9876, session: "demo", startedAt: 1)
        try discovery.write(info)

        let expected = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("demo", isDirectory: true)
            .appendingPathComponent("traces", isDirectory: true)
            .path

        #expect(discovery.readLive() == info)
        #expect(discovery.traceDirectory(for: info).path == expected)
        #expect(automaticSessionTraceOutput(discovery: discovery) == expected)
    }

    @Test func sseEncoderProducesEventStreamFrame() throws {
        let event = ReticleEventEnvelope(
            id: "evt_0000000000000001",
            ts: 1,
            session: "test",
            target: "android:pkg",
            source: "action",
            type: "action.trace",
            payload: ["gesture": .string("tap")]
        )

        let frame = try String(data: SseEncoder().encode(event), encoding: .utf8)
        #expect(frame?.contains("id: evt_0000000000000001\n") == true)
        #expect(frame?.contains("event: action.trace\n") == true)
        #expect(frame?.contains("data: ") == true)
        #expect(frame?.hasSuffix("\n\n") == true)
    }

    @Test func actionTraceIngestReadsTraceFileAndRefsArtifacts() throws {
        let dir = try temporaryDirectory().appendingPathComponent("trace", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let trace = """
        {
          "traceVersion": 1,
          "actionId": "123-tap",
          "packageName": "dev.reticle.sample",
          "recordedAtMillis": 10,
          "gesture": "tap",
          "artifacts": {
            "beforeSnapshot": "before.snapshot.json",
            "afterSnapshot": "after.snapshot.json"
          },
          "diff": [{ "field": "text", "before": "Pay", "after": "Paid" }]
        }
        """
        let traceURL = dir.appendingPathComponent("trace.json")
        try trace.write(to: traceURL, atomically: true, encoding: .utf8)

        let event = try ActionTraceIngest().event(fromTraceAt: traceURL)
        #expect(event.source == "action")
        #expect(event.type == "action.trace")
        #expect(event.target == "android:dev.reticle.sample")
        #expect(event.payload["actionId"]?.stringValue == "123-tap")
        #expect(event.payload["traceVersion"] == .number(1))
        #expect(event.refs["beforeSnapshot"] == dir.appendingPathComponent("before.snapshot.json").path)
        #expect(event.refs["manifest"] == traceURL.path)
    }

    @Test func httpServerAcceptsTraceAndReturnsHistory() async throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "test", rootDirectory: root, limit: 10)
        let server = try ReticleHttpServer(store: store, port: 0)
        try server.start()
        defer { server.stop() }

        let traceURL = try writeTraceFixture(root: root)
        let postURL = URL(string: "http://127.0.0.1:\(server.port)/sessions/current/action-traces")!
        var request = URLRequest(url: postURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["path": traceURL.path])
        let (_, postResponse) = try await URLSession.shared.data(for: request)
        #expect((postResponse as? HTTPURLResponse)?.statusCode == 201)

        let historyURL = URL(string: "http://127.0.0.1:\(server.port)/sessions/current/events")!
        let (data, response) = try await URLSession.shared.data(from: historyURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let decoded = try JSONDecoder().decode(EventsResponse.self, from: data)
        #expect(decoded.events.first?.type == "action.trace")
    }

    @Test func httpServerForwardsHelperRpcWhenBrokerEnabled() async throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "test", rootDirectory: root, limit: 10)
        let helper = FakeHelperClient(result: [
            "version": "test",
            "devices": [["serial": "emulator-5554", "state": "device"]],
        ])
        let server = try ReticleHttpServer(store: store, port: 0, helper: helper)
        try server.start()
        defer { server.stop() }

        let response = try await post(
            URL(string: "http://127.0.0.1:\(server.port)/helper/rpc")!,
            body: HelperRpcRequestFixture(method: "listDevices", params: ["target": "android"])
        )

        #expect(response.status == 200)
        let decoded = try JSONDecoder().decode(HelperRpcResponse.self, from: response.data)
        #expect(decoded.ok)
        #expect(decoded.result?["version"] == .string("test"))
        #expect(helper.calls == ["listDevices"])
    }

    @Test func daemonHelperClientUsesLiveDiscoveryAndForwardsSerial() throws {
        let root = try temporaryDirectory()
        let discovery = DaemonDiscovery(fileURL: root.appendingPathComponent("daemon.json"))
        let store = try EventStore(session: "test", rootDirectory: root, limit: 10)
        let helper = FakeHelperClient(result: ["ok": true])
        let server = try ReticleHttpServer(store: store, port: 0, helper: helper)
        try server.start()
        defer { server.stop() }
        try discovery.write(DaemonInfo(pid: getpid(), port: server.port, session: "test", startedAt: 1))

        let result = try DaemonHelperClient(discovery: discovery, timeout: 2, serial: "device-1")
            .call("status", ["package": "pkg"])

        #expect(result["ok"] as? Bool == true)
        #expect(helper.calls == ["status"])
        #expect(helper.lastParams["serial"] as? String == "device-1")
        #expect(helper.lastParams["package"] as? String == "pkg")
    }

    @Test func httpServerRejectsHelperRpcWithoutBroker() async throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "test", rootDirectory: root, limit: 10)
        let server = try ReticleHttpServer(store: store, port: 0)
        try server.start()
        defer { server.stop() }

        let response = try await post(
            URL(string: "http://127.0.0.1:\(server.port)/helper/rpc")!,
            body: HelperRpcRequestFixture(method: "ping", params: [:])
        )

        #expect(response.status == 404)
    }

    @Test func httpServerServesReadOnlyPanel() async throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "test", rootDirectory: root, limit: 10)
        let server = try ReticleHttpServer(store: store, port: 0)
        try server.start()
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(server.port)/panel")!
        let (data, response) = try await URLSession.shared.data(from: url)
        let text = String(data: data, encoding: .utf8)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.contains("text/html") == true)
        #expect(text?.contains("Reticle Evidence Timeline") == true)
        #expect(text?.contains("session-picker") == true)
        #expect(text?.contains("Network requests") == true)
        #expect(text?.contains("networkNode") == true)
        #expect(text?.contains("networkTransactions") == true)
        #expect(text?.contains("network-filters") == true)
        #expect(text?.contains("networkFilterMatches") == true)
        #expect(text?.contains("MOCK HTTP") == true)
        #expect(text?.contains("mockRuleId") == true)
        #expect(text?.contains("copy-chip") == true)
        #expect(text?.contains("body-preview") == true)
        #expect(text?.contains("Screenshot") == true)
        #expect(text?.contains("shot-body") == true)
        #expect(text?.contains("shot-error") == true)
        #expect(text?.contains("selectorLabel") == true)
        #expect(text?.contains("selector-chips") == true)
        #expect(text?.contains("runtimeNode") == true)
        #expect(text?.contains("runtime.advisory") == true)
        #expect(text?.contains("highest-signal changes") == true)
        #expect(text?.contains("diff-target") == true)
    }

    @Test func httpServerManagesMockRulesAndValues() async throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "test", rootDirectory: root, limit: 10)
        let mockStore = try NetworkMockStore(sessionDirectory: store.sessionDirectory)
        let server = try ReticleHttpServer(store: store, port: 0, mockStore: mockStore)
        try server.start()
        defer { server.stop() }

        let value = NetworkMockValueRequest(
            id: "ok",
            status: 203,
            headers: ["Content-Type": "application/json"],
            body: #"{"ok":true}"#,
            contentType: nil
        )
        let valueResponse = try await post(
            URL(string: "http://127.0.0.1:\(server.port)/sessions/current/mocks/values")!,
            body: value
        )
        #expect(valueResponse.status == 201)

        let rule = NetworkMockRuleRequest(
            id: "rule",
            enabled: true,
            priority: 5,
            method: "GET",
            url: "/api",
            match: .prefix,
            valueId: "ok"
        )
        let ruleResponse = try await post(
            URL(string: "http://127.0.0.1:\(server.port)/sessions/current/mocks/rules")!,
            body: rule
        )
        #expect(ruleResponse.status == 201)

        let listURL = URL(string: "http://127.0.0.1:\(server.port)/sessions/current/mocks/rules")!
        let (rulesData, rulesResponse) = try await URLSession.shared.data(from: listURL)
        #expect((rulesResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(try JSONDecoder().decode(NetworkMockRulesResponse.self, from: rulesData).rules.map(\.id) == ["rule"])

        let resolveResponse = try await post(
            URL(string: "http://127.0.0.1:\(server.port)/sessions/current/mocks/resolve")!,
            body: NetworkMockResolveRequest(method: "GET", url: "http://api.test/api/users")
        )
        #expect(resolveResponse.status == 200)
        #expect(try JSONDecoder().decode(NetworkMockResolveResponse.self, from: resolveResponse.data).rule?.id == "rule")

        let (exportData, exportResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(server.port)/sessions/current/mocks/export")!)
        #expect((exportResponse as? HTTPURLResponse)?.statusCode == 200)
        let exported = try JSONDecoder().decode(NetworkMockExport.self, from: exportData)
        #expect(exported.rules.map(\.id) == ["rule"])
        #expect(exported.values.map(\.id) == ["ok"])

        let clearResponse = try await post(
            URL(string: "http://127.0.0.1:\(server.port)/sessions/current/mocks/clear")!,
            body: EmptyPostBody()
        )
        #expect(clearResponse.status == 200)
        #expect(mockStore.listRules().isEmpty)
        #expect(mockStore.listValues().isEmpty)

        let importResponse = try await post(
            URL(string: "http://127.0.0.1:\(server.port)/sessions/current/mocks/import")!,
            body: exported
        )
        #expect(importResponse.status == 201)
        #expect(mockStore.listRules().map(\.id) == ["rule"])
        #expect(mockStore.listValues().map(\.id) == ["ok"])

        let disableURL = URL(string: "http://127.0.0.1:\(server.port)/sessions/current/mocks/rules/rule/disable")!
        var disableRequest = URLRequest(url: disableURL)
        disableRequest.httpMethod = "POST"
        let (disabledData, disabledResponse) = try await URLSession.shared.data(for: disableRequest)
        #expect((disabledResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(try JSONDecoder().decode(NetworkMockRule.self, from: disabledData).enabled == false)

        var deleteValue = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/sessions/current/mocks/values/ok")!)
        deleteValue.httpMethod = "DELETE"
        let (_, rejectedDelete) = try await URLSession.shared.data(for: deleteValue)
        #expect((rejectedDelete as? HTTPURLResponse)?.statusCode == 400)

        var deleteRule = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/sessions/current/mocks/rules/rule")!)
        deleteRule.httpMethod = "DELETE"
        let (_, removedRule) = try await URLSession.shared.data(for: deleteRule)
        #expect((removedRule as? HTTPURLResponse)?.statusCode == 200)

        let (_, removedValue) = try await URLSession.shared.data(for: deleteValue)
        #expect((removedValue as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test func httpServerServesArtifactsOnlyThroughEventRefs() async throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "test", rootDirectory: root, limit: 10)
        let artifactURL = root.appendingPathComponent("before.snapshot.json")
        try #"{"ok":true}"#.write(to: artifactURL, atomically: true, encoding: .utf8)
        let missingURL = root.appendingPathComponent("missing.snapshot.json")
        let event = try store.append(EventPostRequest(
            source: "action",
            type: "action.trace",
            refs: [
                "beforeSnapshot": artifactURL.path,
                "missingFile": missingURL.path
            ]
        ))
        let server = try ReticleHttpServer(store: store, port: 0)
        try server.start()
        defer { server.stop() }

        let okURL = URL(string: "http://127.0.0.1:\(server.port)/sessions/current/artifacts?event=\(event.id)&ref=beforeSnapshot")!
        let (data, okResponse) = try await URLSession.shared.data(from: okURL)
        #expect((okResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8) == #"{"ok":true}"#)

        let missingRefURL = URL(string: "http://127.0.0.1:\(server.port)/sessions/current/artifacts?event=\(event.id)&ref=afterSnapshot")!
        let (_, missingRefResponse) = try await URLSession.shared.data(from: missingRefURL)
        #expect((missingRefResponse as? HTTPURLResponse)?.statusCode == 404)

        let missingFileURL = URL(string: "http://127.0.0.1:\(server.port)/sessions/current/artifacts?event=\(event.id)&ref=missingFile")!
        let (_, missingFileResponse) = try await URLSession.shared.data(from: missingFileURL)
        #expect((missingFileResponse as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test func httpServerServesHistoricalSessionsAndArtifacts() async throws {
        let root = try temporaryDirectory()
        let historical = try EventStore(session: "old", rootDirectory: root, limit: 10)
        let artifactURL = historical.sessionDirectory.appendingPathComponent("old.snapshot.json")
        try #"{"old":true}"#.write(to: artifactURL, atomically: true, encoding: .utf8)
        let oldEvent = try historical.append(EventPostRequest(
            source: "action",
            type: "action.trace",
            refs: ["beforeSnapshot": artifactURL.path]
        ))
        let current = try EventStore(session: "current", rootDirectory: root, limit: 10)
        _ = try current.append(EventPostRequest(source: "log", type: "log"))
        let server = try ReticleHttpServer(store: current, port: 0)
        try server.start()
        defer { server.stop() }

        let sessionsURL = URL(string: "http://127.0.0.1:\(server.port)/sessions")!
        let (sessionsData, sessionsResponse) = try await URLSession.shared.data(from: sessionsURL)
        #expect((sessionsResponse as? HTTPURLResponse)?.statusCode == 200)
        let sessions = try JSONDecoder().decode(SessionsResponse.self, from: sessionsData).sessions
        #expect(sessions.contains { $0.id == "old" && $0.actionTraceCount == 1 && !$0.isCurrent })
        #expect(sessions.contains { $0.id == "current" && $0.isCurrent })

        let eventsURL = URL(string: "http://127.0.0.1:\(server.port)/sessions/old/events")!
        let (eventsData, eventsResponse) = try await URLSession.shared.data(from: eventsURL)
        #expect((eventsResponse as? HTTPURLResponse)?.statusCode == 200)
        let events = try JSONDecoder().decode(EventsResponse.self, from: eventsData).events
        #expect(events.map(\.id) == [oldEvent.id])

        let artifactURLString = "http://127.0.0.1:\(server.port)/sessions/old/artifacts?event=\(oldEvent.id)&ref=beforeSnapshot"
        let (artifactData, artifactResponse) = try await URLSession.shared.data(from: URL(string: artifactURLString)!)
        #expect((artifactResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: artifactData, encoding: .utf8) == #"{"old":true}"#)
    }

    @Test func httpServerRejectsMalformedEventBody() async throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "test", rootDirectory: root, limit: 10)
        let server = try ReticleHttpServer(store: store, port: 0)
        try server.start()
        defer { server.stop() }

        let postURL = URL(string: "http://127.0.0.1:\(server.port)/sessions/current/events")!
        var request = URLRequest(url: postURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{".utf8)

        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
    }

    @Test func httpServerSseReplaysExistingEvents() throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "test", rootDirectory: root, limit: 10)
        _ = try store.append(EventPostRequest(source: "ui", type: "ui.snapshot"))
        let server = try ReticleHttpServer(store: store, port: 0)
        try server.start()
        defer { server.stop() }

        let text = try readSocket(
            port: server.port,
            request: "GET /events/stream HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        )
        #expect(text.lowercased().contains("content-type: text/event-stream"))
        #expect(text.contains("event: ui.snapshot"))
    }

    @Test func evictedCurrentSessionEventStillResolvesFromDisk() throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "test", rootDirectory: root, limit: 1)

        let first = try store.append(EventPostRequest(source: "ui", type: "ui.snapshot"))
        _ = try store.append(EventPostRequest(source: "ui", type: "ui.snapshot"))

        // `first` has aged out of the in-memory ring (limit 1)...
        #expect(store.event(id: first.id) == nil)
        // ...but its artifact lookup must still find it, from events.jsonl.
        #expect(try store.historicalEvent(session: "test", eventId: first.id)?.id == first.id)
    }

    @Test func artifactPathsAreConfinedToAllowedRoots() throws {
        let root = try temporaryDirectory()
        let store = try EventStore(session: "test", rootDirectory: root, limit: 10)

        // A file under the sessions root (where in-process producers write) is
        // allowed; an arbitrary file outside it is not.
        let inside = root.appendingPathComponent("test/network-bodies/x.bin")
        #expect(store.isArtifactPathAllowed(inside))
        #expect(!store.isArtifactPathAllowed(URL(fileURLWithPath: "/etc/passwd")))

        // A trace directory becomes allowed only after it is explicitly registered.
        let traceDir = try temporaryDirectory().appendingPathComponent("out", isDirectory: true)
        let traceArtifact = traceDir.appendingPathComponent("before.json")
        #expect(!store.isArtifactPathAllowed(traceArtifact))
        store.registerArtifactRoot(traceDir)
        #expect(store.isArtifactPathAllowed(traceArtifact))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeTraceFixture(root: URL) throws -> URL {
        let dir = root.appendingPathComponent("trace", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let traceURL = dir.appendingPathComponent("trace.json")
        try """
        {"actionId":"1-tap","packageName":"pkg","recordedAtMillis":1,"gesture":"tap","artifacts":{"beforeSnapshot":"before.json","afterSnapshot":"after.json"},"diff":[]}
        """.write(to: traceURL, atomically: true, encoding: .utf8)
        return traceURL
    }

    private func post<T: Encodable>(_ url: URL, body: T) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func readSocket(port: Int, request: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestFailure.socket }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw TestFailure.connect }
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var bytes = Data()
        for _ in 0..<8 {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            if String(decoding: bytes, as: UTF8.self).contains("event:") { break }
        }
        close(fd)
        guard !bytes.isEmpty else { throw TestFailure.read }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private struct HelperRpcRequestFixture: Encodable {
    let method: String
    let params: [String: String]
}

private final class FakeHelperClient: HelperCalling, @unchecked Sendable {
    private let result: [String: Any]
    private let lock = NSLock()
    private(set) var calls: [String] = []
    private(set) var lastParams: [String: Any] = [:]

    init(result: [String: Any]) {
        self.result = result
    }

    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        lock.lock()
        calls.append(method)
        lastParams = params
        lock.unlock()
        return result
    }
}

private enum TestFailure: Error {
    case socket
    case connect
    case read
}

private struct EmptyPostBody: Encodable {}
