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

    @Test func blockRuleResolvesWithoutAValue() throws {
        let store = try makeStore()
        try store.upsertRule(request(id: "b", url: "/api", actions: NetworkRuleActions(route: .block)))
        let result = try store.resolve(NetworkRuleRequestContext(method: "GET", url: "http://h/api/x", path: "/api/x"))
        #expect(result?.rule.id == "b")
        #expect(result?.value == nil)
        #expect(result?.rule.actions.route.label == "block")
    }

    @Test func mapRemoteRequiresAnAbsoluteOrigin() throws {
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

    @Test func mockRouteRefusesDeletingAReferencedValue() throws {
        let store = try makeStore()
        try store.upsertValue(NetworkMockValueRequest(id: "v", status: 200, headers: [:], body: "{}", contentType: "application/json"))
        try store.upsertRule(request(id: "r", url: "/api", actions: NetworkRuleActions(route: .mock(valueId: "v"))))
        #expect(throws: NetworkRuleError.self) { try store.removeValue(id: "v") }
        // Removing the rule frees the value for deletion.
        try store.removeRule(id: "r")
        try store.removeValue(id: "v")
        #expect(store.listValues().isEmpty)
    }

    @Test func negativeDelayIsRejected() throws {
        let store = try makeStore()
        #expect(throws: NetworkRuleError.self) {
            try store.upsertRule(self.request(id: "d", url: "/api", actions: NetworkRuleActions(route: .passthrough, delayMs: -1)))
        }
    }

    @Test func actionsSurviveAtaggedUnionRoundTrip() throws {
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

    @Test func rulesPersistAndReloadAcrossStoreInstances() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try NetworkRuleStore(sessionDirectory: dir)
        try store.upsertRule(request(id: "b", url: "/api", actions: NetworkRuleActions(route: .block, delayMs: 100)))
        let reloaded = try NetworkRuleStore(sessionDirectory: dir)
        #expect(reloaded.listRules().first?.actions.route.label == "block")
        #expect(reloaded.listRules().first?.actions.delayMs == 100)
    }
}
