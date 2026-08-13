import Foundation
import Testing
@testable import ReticleNetworkLane

/// Exercises the generalized traffic-rule store: the block / mapRemote / mock routes
/// and their modifiers, action validation, referential integrity between a mock
/// route and its value, and the tagged-union JSON round-trip that persists rules.
@Suite("Network rule store")
struct NetworkRuleStoreTests {
    private func makeStore() throws -> NetworkRuleStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try NetworkRuleStore(sessionDirectory: dir)
    }

    private func request(id: String, url: String, match: NetworkRuleMatch = .prefix, actions: NetworkRuleActions) -> NetworkRuleRequest {
        NetworkRuleRequest(id: id, enabled: true, priority: 0, method: "GET", url: url, match: match, actions: actions)
    }

    @Test func blockRuleResolvesWithoutAValue() async throws {
        let store = try makeStore()
        try store.upsertRule(request(id: "b", url: "/api", actions: NetworkRuleActions(route: .block)))
        let result = try store.resolve(NetworkRuleRequestContext(method: "GET", url: "http://h/api/x", path: "/api/x"))
        #expect(result?.rule.id == "b")
        #expect(result?.value == nil)
        #expect(result?.rule.actions.route.label == "block")
    }

    @Test func mapRemoteRequiresAnAbsoluteOrigin() async throws {
        let store = try makeStore()
        #expect(throws: NetworkRuleError.self) {
            try store.upsertRule(self.request(id: "m", url: "/api", actions: NetworkRuleActions(route: .mapRemote(NetworkMapRemote(destination: "not-a-url")))))
        }
        // A valid origin is accepted and round-trips the destination.
        try store.upsertRule(request(id: "m", url: "/api", actions: NetworkRuleActions(route: .mapRemote(NetworkMapRemote(destination: "https://staging.example.com", keepHostHeader: true)))))
        guard case let .mapRemote(action) = store.listRules().first?.actions.route else {
            Issue.record("expected mapRemote route"); return
        }
        #expect(action.destination == "https://staging.example.com")
        #expect(action.keepHostHeader == true)
    }

    @Test func mockRouteRefusesDeletingAReferencedValue() async throws {
        let store = try makeStore()
        try store.upsertValue(NetworkMockValueRequest(id: "v", status: 200, headers: [:], body: "{}", contentType: "application/json"))
        try store.upsertRule(request(id: "r", url: "/api", actions: NetworkRuleActions(route: .mock(valueId: "v"))))
        #expect(throws: NetworkRuleError.self) { try store.removeValue(id: "v") }
        // Removing the rule frees the value for deletion.
        try store.removeRule(id: "r")
        try store.removeValue(id: "v")
        #expect(store.listValues().isEmpty)
    }

    @Test func negativeDelayIsRejected() async throws {
        let store = try makeStore()
        #expect(throws: NetworkRuleError.self) {
            try store.upsertRule(self.request(id: "d", url: "/api", actions: NetworkRuleActions(route: .passthrough, delayMs: -1)))
        }
    }

    @Test func actionsSurviveAtaggedUnionRoundTrip() async throws {
        let actions = NetworkRuleActions(
            route: .mapRemote(NetworkMapRemote(destination: "http://127.0.0.1:3001")),
            delayMs: 250,
            rewriteRequest: NetworkHeaderRewrite(setHeaders: ["X-Test": "1"], removeHeaders: ["Authorization"]),
            responseSubstitutions: [NetworkSubstitution(field: .body, match: "a", replacement: "b")]
        )
        let data = try JSONEncoder().encode(actions)
        let decoded = try JSONDecoder().decode(NetworkRuleActions.self, from: data)
        #expect(decoded == actions)
        #expect(decoded.isNoOp == false)
        #expect(NetworkRuleActions().isNoOp == true)
    }

    @Test func rulesPersistAndReloadAcrossStoreInstances() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try NetworkRuleStore(sessionDirectory: dir)
        try store.upsertRule(request(id: "b", url: "/api", actions: NetworkRuleActions(route: .block, delayMs: 100)))
        let reloaded = try NetworkRuleStore(sessionDirectory: dir)
        #expect(reloaded.listRules().first?.actions.route.label == "block")
        #expect(reloaded.listRules().first?.actions.delayMs == 100)
    }

    @Test func importAppliesTheWholePackageWithOneSyncPerFile() async throws {
        let store = try makeStore()
        var syncs = 0
        store.onChange = { syncs += 1 }
        let package = NetworkRuleExport(
            rules: (0..<5).map {
                NetworkRule(id: "r\($0)", enabled: true, priority: 0, method: "GET",
                            url: "/api/\($0)", match: .prefix, host: nil, query: nil,
                            actions: NetworkRuleActions(route: .mock(valueId: "v\($0)")))
            },
            values: (0..<5).map {
                NetworkMockExportValue(id: "v\($0)", status: 200, headers: [:],
                                       contentType: "application/json",
                                       bodyBase64: Data("{\"i\":\($0)}".utf8).base64EncodedString())
            }
        )
        try store.importPackage(package)

        #expect(store.listRules().count == 5)
        #expect(store.listValues().count == 5)
        // One values write + one rules write, not 2N.
        #expect(syncs == 2)
        let resolved = try store.resolve(
            NetworkRuleRequestContext(method: "GET", url: "http://h/api/3", path: "/api/3"))
        #expect(resolved?.rule.id == "r3")
        #expect(resolved.flatMap { $0.body.map { String(decoding: $0, as: UTF8.self) } } == "{\"i\":3}")
    }

    @Test func aRejectedEntryLeavesTheIndexUntouched() async throws {
        let store = try makeStore()
        try store.upsertRule(request(id: "keep", url: "/api", actions: NetworkRuleActions(route: .block)))
        let bad = NetworkRuleExport(
            rules: [
                NetworkRule(id: "ok", enabled: true, priority: 0, method: "GET", url: "/a",
                            match: .prefix, host: nil, query: nil,
                            actions: NetworkRuleActions(route: .block)),
                NetworkRule(id: "bad", enabled: true, priority: 0, method: "GET", url: "(",
                            match: .regex, host: nil, query: nil,
                            actions: NetworkRuleActions(route: .block)),
            ],
            values: []
        )
        #expect(throws: NetworkRuleError.self) { try store.importPackage(bad) }
        #expect(store.listRules().map(\.id) == ["keep"])
    }
}
