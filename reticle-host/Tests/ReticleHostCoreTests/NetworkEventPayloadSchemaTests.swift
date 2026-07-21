import Foundation
import Testing
@testable import ReticleHostCore
@testable import ReticleNetworkLane

/// Ties the Swift host — the SOLE producer of proxy `network.*` payloads — to the
/// typed payload schema in reticle-protocol/. The Kotlin contract test proves the
/// golden fixtures satisfy that schema; this suite proves the emitter that
/// actually fills those payloads agrees with the same field set, so neither side
/// can add, rename, or drop a field without the other noticing.
@Suite("Network event payload schema")
struct NetworkEventPayloadSchemaTests {

    private func schemaProperties() throws -> (declared: Set<String>, required: Set<String>) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReticleHostCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // reticle-host
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("reticle-protocol/schema/network-event-payload.schema.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        let properties = Array((object["properties"] as? [String: Any])?.keys ?? [:].keys)
        let required = (object["required"] as? [String]) ?? []
        return (Set(properties), Set(required))
    }

    @Test func emittedPayloadKeysAreAllDeclaredInTheSchema() throws {
        let (declared, _) = try schemaProperties()
        var payload = NetworkEventPayload(
            requestId: "r", scheme: "https", method: "GET", url: "u",
            host: "h", port: 443, path: "/", startMillis: 1, tunnel: false, mitm: true
        )
        payload.endMillis = 2
        payload.status = 200
        payload.error = "boom"
        payload.requestHeaders = ["Accept": "application/json"]
        payload.responseHeaders = ["Content-Type": "application/json"]
        payload.requestBodyBytes = 1
        payload.responseBodyBytes = 2
        payload.requestBodyTruncated = false
        payload.responseBodyTruncated = true
        payload.mocked = true
        payload.mockRuleId = "rule"
        payload.mockValueId = "value"

        let emitted = Set(payload.json.keys)
        let undeclared = emitted.subtracting(declared)
        #expect(undeclared.isEmpty, "emitter produced fields the schema does not declare: \(undeclared.sorted())")
        // durationMs is derived only when endMillis is set — prove it appears and
        // is covered by the schema.
        #expect(emitted.contains("durationMs"))
    }

    @Test func minimalPayloadCarriesEveryRequiredField() throws {
        let (_, required) = try schemaProperties()
        let payload = NetworkEventPayload(
            requestId: "r", scheme: "http", method: "GET", url: "u",
            host: "h", port: 80, path: "/", startMillis: 1, tunnel: false, mitm: false
        )
        let emitted = Set(payload.json.keys)
        let missing = required.subtracting(emitted)
        #expect(missing.isEmpty, "emitter omitted schema-required fields: \(missing.sorted())")
    }
}
