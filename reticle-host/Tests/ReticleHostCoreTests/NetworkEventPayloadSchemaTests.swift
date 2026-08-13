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

    private func schemaProperties(
        _ file: String = "network-event-payload.schema.json"
    ) throws -> (declared: Set<String>, required: Set<String>) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReticleHostCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // reticle-host
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("reticle-protocol/schema/\(file)")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        let properties = Array((object["properties"] as? [String: Any])?.keys ?? [:].keys)
        let required = (object["required"] as? [String]) ?? []
        return (Set(properties), Set(required))
    }

    /// The diff is nested inside the payload, so its own fields need the same
    /// pinning — an undeclared key there fails the Kotlin contract test just as hard.
    private func diffSchemaProperties() throws -> Set<String> {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("reticle-protocol/schema/network-event-payload.schema.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        let properties = object["properties"] as? [String: Any] ?? [:]
        let diff = properties["diff"] as? [String: Any] ?? [:]
        return Set((diff["properties"] as? [String: Any])?.keys ?? [:].keys)
    }

    @Test func emittedPayloadKeysAreAllDeclaredInTheSchema() async throws {
        let (declared, _) = try schemaProperties()
        var payload = NetworkEventPayload(
            requestId: "r", scheme: "https", method: "GET", url: "u",
            host: "h", port: 443, path: "/", startMillis: 1, tunnel: false, mitm: true
        )
        payload.firstByteMillis = 2
        payload.endMillis = 3
        payload.status = 200
        payload.error = "boom"
        payload.requestHeaders = ["Accept": "application/json"]
        payload.responseHeaders = ["Content-Type": "application/json"]
        payload.requestBodyBytes = 1
        payload.responseBodyBytes = 2
        payload.requestBodyTruncated = false
        payload.responseBodyTruncated = true
        payload.ruleApplied = true
        payload.ruleId = "rule"
        payload.ruleAction = "mock"
        payload.mockValueId = "value"
        payload.replayedFrom = "source-id"
        payload.diff = NetworkReplayDiff(
            statusFrom: 200, statusTo: 500, statusChanged: true,
            bodyBytesFrom: 1, bodyBytesTo: 2, bodyChanged: true,
            headersAdded: ["a"], headersRemoved: ["b"], headersChanged: ["c"],
            bodyComparisonPartial: true
        )

        let emitted = Set(payload.json.keys)
        let undeclared = emitted.subtracting(declared)
        #expect(undeclared.isEmpty, "emitter produced fields the schema does not declare: \(undeclared.sorted())")
        // durationMs is derived only when endMillis is set — prove it appears and
        // is covered by the schema.
        #expect(emitted.contains("durationMs"))
        // Same for the timing split, which is derived only alongside firstByteMillis.
        #expect(emitted.contains("ttfbMs"))
        #expect(emitted.contains("receiveMs"))
    }

    /// The nested diff drifts just as easily as the payload, and `additionalProperties:
    /// false` applies there too.
    @Test func emittedDiffKeysAreAllDeclaredInTheSchema() async throws {
        let declared = try diffSchemaProperties()
        let diff = NetworkReplayDiff.between(
            sourceStatus: 200, sourceHeaders: ["a": "1"], sourceBody: Data("x".utf8), sourceWireBytes: 4096,
            replayStatus: 500, replayHeaders: ["b": "2"], replayBody: Data("y".utf8), replayWireBytes: 8192
        )
        var payload = NetworkEventPayload(
            requestId: "r", scheme: "https", method: "GET", url: "u",
            host: "h", port: 443, path: "/", startMillis: 1, tunnel: false, mitm: true
        )
        payload.diff = diff
        guard case .object(let encoded)? = payload.json["diff"] else {
            Issue.record("diff did not encode as an object")
            return
        }
        let undeclared = Set(encoded.keys).subtracting(declared)
        #expect(undeclared.isEmpty, "diff produced fields the schema does not declare: \(undeclared.sorted())")
        #expect(encoded["bodyComparisonPartial"] != nil, "a capped comparison must say so in the emitted diff")
    }

    /// Same pinning for the advisory payload, with both edges exercised: `overflow`
    /// deliberately omits `droppedFlows`, so only checking `recovered` would leave
    /// the required-field claim untested for the shape that actually ships first.
    @Test func emittedAdvisoryPayloadKeysAreAllDeclaredInTheSchema() async throws {
        let (declared, required) = try schemaProperties("network-advisory-payload.schema.json")

        let overflow = NetworkAdvisoryPayload(
            kind: "capture-backlog-overflow", message: "full", droppedFlowsTotal: 1
        )
        var recovered = NetworkAdvisoryPayload(
            kind: "capture-backlog-recovered", message: "caught up", droppedFlowsTotal: 104
        )
        recovered.droppedFlows = 104

        for payload in [overflow, recovered] {
            let emitted = Set(payload.json.keys)
            #expect(emitted.subtracting(declared).isEmpty,
                    "advisory emitter produced undeclared fields: \(emitted.subtracting(declared).sorted())")
            #expect(required.subtracting(emitted).isEmpty,
                    "advisory emitter omitted required fields: \(required.subtracting(emitted).sorted())")
        }
        #expect(overflow.json["droppedFlows"] == nil)
    }

    /// The frame payload is its own shape with its own schema; pin the emitter to it
    /// the same way, with every optional field populated so nothing escapes unnoticed.
    @Test func emittedWebSocketPayloadKeysAreAllDeclaredInTheSchema() async throws {
        let (declared, required) = try schemaProperties("network-websocket-payload.schema.json")
        var payload = NetworkWebSocketPayload(
            requestId: "r", url: "wss://h/live", host: "h", frameIndex: 0,
            direction: "serverToClient", kind: "text", isFinal: true,
            bytes: 3, frameMillis: 1
        )
        payload.textPreview = "hi"
        payload.textPreviewTruncated = true
        payload.capReached = true
        payload.framesRecorded = 1000
        payload.framesNotRecorded = 7

        let emitted = Set(payload.json.keys)
        #expect(emitted.subtracting(declared).isEmpty,
                "websocket emitter produced fields the schema does not declare: \(emitted.subtracting(declared).sorted())")
        #expect(required.subtracting(emitted).isEmpty,
                "websocket emitter omitted schema-required fields: \(required.subtracting(emitted).sorted())")
    }

    @Test func minimalPayloadCarriesEveryRequiredField() async throws {
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
