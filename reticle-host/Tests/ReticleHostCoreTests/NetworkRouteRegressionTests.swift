import Foundation
import Testing
@testable import ReticleHostCore
@testable import ReticleNetworkLane

/// Records what the route handed down, and answers with whatever the test staged —
/// including a failure, which is the half no live lane can be asked for on demand.
private final class StubReplayer: FlowReplaying, @unchecked Sendable {
    private let lock = NSLock()
    private var _receivedId: String?
    private var _receivedRequest: NetworkReplayRequest?
    private let outcome: Result<NetworkReplayResult, NetworkReplayError>

    var receivedId: String? { lock.withLock { _receivedId } }
    var receivedRequest: NetworkReplayRequest? { lock.withLock { _receivedRequest } }

    init(_ outcome: Result<NetworkReplayResult, NetworkReplayError>) { self.outcome = outcome }

    func replay(requestId: String, request: NetworkReplayRequest) throws -> NetworkReplayResult {
        lock.withLock {
            _receivedId = requestId
            _receivedRequest = request
        }
        return try outcome.get()
    }
}

private func replayResult(_ id: String = "new") -> NetworkReplayResult {
    NetworkReplayResult(
        requestId: id,
        replayedFrom: "source",
        status: 200,
        error: nil,
        diff: NetworkReplayDiff(
            statusFrom: 200, statusTo: 200, statusChanged: false,
            bodyBytesFrom: 1, bodyBytesTo: 1, bodyChanged: false,
            headersAdded: [], headersRemoved: [], headersChanged: [],
            bodyComparisonPartial: false
        )
    )
}

/// Route-level regression net for the two network endpoints that had none: replay and
/// the rule surface. The stores and the translation layer are unit-tested elsewhere;
/// what is pinned here is the HTTP contract on top of them — which status code an agent
/// sees, and whether the body it sent survived the trip. Those are exactly the parts a
/// refactor of the routes can change without any store test noticing.
@Suite("Network route regressions")
struct NetworkRouteRegressionTests {
    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reticle-net-routes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func serve(replayer: FlowReplaying? = nil, withRuleStore: Bool = false) throws
        -> (server: ReticleHttpServer, ruleStore: NetworkRuleStore?) {
        let store = try EventStore(session: "test", rootDirectory: try temporaryDirectory(), limit: 10)
        let ruleStore = withRuleStore ? try NetworkRuleStore(sessionDirectory: store.sessionDirectory) : nil
        let server = try ReticleHttpServer(store: store, port: 0, ruleStore: ruleStore)
        server.flowReplayer = replayer
        try server.start()
        return (server, ruleStore)
    }

    private func post(_ url: URL, rawBody: Data?) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = rawBody
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    private func post<Body: Encodable>(_ url: URL, body: Body) async throws -> (status: Int, data: Data) {
        try await post(url, rawBody: try JSONEncoder().encode(body))
    }

    private func delete(_ url: URL) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? -1
    }

    // MARK: - POST /sessions/current/flows/:id/replay

    /// An empty body means "replay it verbatim". Decoding it as a bad request instead
    /// would make the simplest possible replay the one that cannot be asked for.
    @Test func anEmptyReplayBodyMeansNoOverrides() async throws {
        let replayer = StubReplayer(.success(replayResult()))
        let (server, _) = try serve(replayer: replayer)
        defer { server.stop() }

        let (status, data) = try await post(
            URL(string: "http://127.0.0.1:\(server.port)/sessions/current/flows/flow-1/replay")!,
            rawBody: nil
        )

        #expect(status == 200)
        #expect(replayer.receivedId == "flow-1")
        let received = try #require(replayer.receivedRequest)
        #expect(received.method == nil)
        #expect(received.url == nil)
        #expect(received.setHeaders == nil)
        #expect(received.clearBody == nil)
        #expect(try JSONDecoder().decode(NetworkReplayResult.self, from: data).requestId == "new")
    }

    @Test func replayOverridesReachTheLaneUnchanged() async throws {
        let replayer = StubReplayer(.success(replayResult()))
        let (server, _) = try serve(replayer: replayer)
        defer { server.stop() }

        let overrides = NetworkReplayRequest(
            method: "POST",
            url: "https://api.example.com/v1/retry",
            setHeaders: ["X-Retry": "1"],
            removeHeaders: ["Cookie"],
            body: #"{"again":true}"#,
            clearBody: false
        )
        let (status, _) = try await post(
            URL(string: "http://127.0.0.1:\(server.port)/sessions/current/flows/flow-2/replay")!,
            body: overrides
        )

        #expect(status == 200)
        let received = try #require(replayer.receivedRequest)
        #expect(received.method == "POST")
        #expect(received.url == "https://api.example.com/v1/retry")
        #expect(received.setHeaders == ["X-Retry": "1"])
        #expect(received.removeHeaders == ["Cookie"])
        #expect(received.body == #"{"again":true}"#)
        #expect(received.clearBody == false)
    }

    /// The three replay failures are three different things to do about them — retry a
    /// different id, fix the override, or look at the upstream — so they must not
    /// collapse into one status code.
    @Test func eachReplayFailureKeepsItsOwnStatusCode() async throws {
        let cases: [(NetworkReplayError, Int)] = [
            (.notFound("no flow with id flow-x"), 404),
            (.invalid("url must be absolute"), 400),
            (.failed("upstream refused the connection"), 502)
        ]
        for (error, expected) in cases {
            let (server, _) = try serve(replayer: StubReplayer(.failure(error)))
            defer { server.stop() }
            let (status, data) = try await post(
                URL(string: "http://127.0.0.1:\(server.port)/sessions/current/flows/flow-x/replay")!,
                rawBody: nil
            )
            #expect(status == expected, "\(error.description) should map to \(expected), got \(status)")
            // The message travels with it — a bare status leaves an agent guessing.
            #expect(String(data: data, encoding: .utf8)?.contains(error.description) == true)
        }
    }

    @Test func malformedReplayJsonIsRejectedRatherThanTreatedAsVerbatim() async throws {
        let replayer = StubReplayer(.success(replayResult()))
        let (server, _) = try serve(replayer: replayer)
        defer { server.stop() }

        let (status, _) = try await post(
            URL(string: "http://127.0.0.1:\(server.port)/sessions/current/flows/flow-3/replay")!,
            rawBody: Data(#"{"method":"#.utf8)
        )

        #expect(status == 400)
        #expect(replayer.receivedId == nil, "a body that did not parse must not reach the lane")
    }

    /// Replay with no capture lane bound is a 404 that says why, not a 500: `serve`
    /// without the proxy is a legitimate configuration, and the fix is a flag.
    @Test func replayWithoutACaptureLaneSaysSoRatherThanFailing() async throws {
        let (server, _) = try serve(replayer: nil)
        defer { server.stop() }

        let (status, data) = try await post(
            URL(string: "http://127.0.0.1:\(server.port)/sessions/current/flows/flow-4/replay")!,
            rawBody: nil
        )

        #expect(status == 404)
        #expect(String(data: data, encoding: .utf8)?.contains("capture proxy") == true)
    }

    // MARK: - The rule surface

    /// Every rule-store failure has a distinct meaning, and the route is the only place
    /// they become status codes an agent can branch on.
    @Test func ruleStoreFailuresMapToDistinctStatusCodes() async throws {
        let (server, _) = try serve(withRuleStore: true)
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)/sessions/current/rules"

        // A rule whose mock value does not exist is ACCEPTED — a mock may legitimately
        // be authored before the value it references — but resolving against it is a
        // 400 that names the gap rather than a silent "no rule matched".
        let (missingValue, _) = try await post(URL(string: base)!, body: NetworkRuleRequest(
            id: "orphan", enabled: true, priority: 0, method: "GET", url: "/api",
            match: .prefix, actions: NetworkRuleActions(route: .mock(valueId: "nope"))
        ))
        #expect(missingValue == 201)
        let (orphanResolve, orphanBody) = try await post(
            URL(string: base + "/resolve")!,
            body: NetworkRuleResolveRequest(method: "GET", url: "https://api.test/api/users")
        )
        #expect(orphanResolve == 400)
        #expect(String(data: orphanBody, encoding: .utf8)?.contains("missing value nope") == true)
        #expect(try await delete(URL(string: base + "/orphan")!) == 200)

        // An empty url is invalid, not an implicit match-everything.
        let (invalid, _) = try await post(URL(string: base)!, body: NetworkRuleRequest(
            id: "blank", enabled: true, priority: 0, method: "GET", url: "",
            match: .prefix, actions: NetworkRuleActions(route: .block)
        ))
        #expect(invalid == 400)

        // Acting on a rule that isn't there is a 404, on every verb that names one.
        let (enableUnknown, _) = try await post(URL(string: base + "/ghost/enable")!, rawBody: nil)
        #expect(enableUnknown == 404)
        let (disableUnknown, _) = try await post(URL(string: base + "/ghost/disable")!, rawBody: nil)
        #expect(disableUnknown == 404)
        #expect(try await delete(URL(string: base + "/ghost")!) == 404)
        #expect(try await delete(URL(string: base + "/values/ghost")!) == 404)

        // Malformed JSON is a bad request, never a partially-applied rule.
        let (malformed, _) = try await post(URL(string: base)!, rawBody: Data(#"{"id":"#.utf8))
        #expect(malformed == 400)

        // `resolve` needs an absolute URL: a path alone cannot be matched against
        // host-scoped rules, and guessing an origin would resolve the wrong rule.
        let (relative, relativeBody) = try await post(
            URL(string: base + "/resolve")!,
            body: NetworkRuleResolveRequest(method: "GET", url: "/api/users")
        )
        #expect(relative == 400)
        #expect(String(data: relativeBody, encoding: .utf8)?.contains("absolute") == true)
    }

    /// The `values` sub-resource is registered ahead of the `:id` routes so the static
    /// segment is never captured as a rule id. That ordering is invisible in the source
    /// once someone reorders the file, and getting it wrong turns every value call into
    /// an operation on a rule named "values".
    @Test func theValuesSegmentIsNeverCapturedAsARuleId() async throws {
        let (server, ruleStore) = try serve(withRuleStore: true)
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)/sessions/current/rules"

        let (created, _) = try await post(URL(string: base + "/values")!, body: NetworkMockValueRequest(
            id: "ok", status: 200, headers: [:], body: #"{"ok":true}"#, contentType: nil
        ))
        #expect(created == 201)
        #expect(try #require(ruleStore).listValues().map(\.id) == ["ok"])
        #expect(try #require(ruleStore).listRules().isEmpty, "no rule named `values` was invented")

        // And the value list is reachable as a list rather than resolving to a rule.
        let (listData, listResponse) = try await URLSession.shared.data(
            from: URL(string: base + "/values")!)
        #expect((listResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(try JSONDecoder().decode(NetworkMockValuesResponse.self, from: listData).values.map(\.id) == ["ok"])
    }

    /// Without a rule store the whole surface answers 404 with a reason. Serving a
    /// plausible empty list instead would read as "no rules are active" on a daemon
    /// that cannot hold rules at all.
    @Test func theRuleSurfaceWithoutAStoreSaysItIsUnavailable() async throws {
        let (server, _) = try serve(withRuleStore: false)
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)/sessions/current/rules"

        for path in ["", "/values", "/export"] {
            let (_, response) = try await URLSession.shared.data(from: URL(string: base + path)!)
            #expect((response as? HTTPURLResponse)?.statusCode == 404, "GET \(base + path)")
        }
        let (clear, clearBody) = try await post(URL(string: base + "/clear")!, rawBody: nil)
        #expect(clear == 404)
        #expect(String(data: clearBody, encoding: .utf8)?.contains("rule store") == true)
    }
}
