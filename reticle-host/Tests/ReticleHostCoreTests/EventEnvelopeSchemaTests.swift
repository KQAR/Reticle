import Foundation
import Testing
@testable import ReticleHostCore

/// Ties the Swift host — the SOLE producer of the event envelope — to the
/// language-neutral golden fixtures in reticle-protocol/. The Kotlin contract
/// test only proves the fixtures satisfy the schema; nothing proved the Swift
/// model that actually emits events agrees with them until this suite.
@Suite("Event envelope schema")
struct EventEnvelopeSchemaTests {

    private func fixturesDirectory() -> URL {
        // <repo>/reticle-host/Tests/ReticleHostCoreTests/<thisfile>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReticleHostCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // reticle-host
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("reticle-protocol/fixtures", isDirectory: true)
    }

    private func decodeFixture(_ name: String) throws -> ReticleEventEnvelope {
        let url = fixturesDirectory().appendingPathComponent(name)
        return try JSONDecoder().decode(ReticleEventEnvelope.self, from: Data(contentsOf: url))
    }

    @Test func goldenEventFixturesDecodeThroughTheProducerModel() throws {
        for name in ["action-trace-event.golden.json", "network-response-event.golden.json"] {
            let event = try decodeFixture(name)
            #expect(event.schemaVersion == ReticleEventEnvelope.currentSchemaVersion)
            #expect(event.id.hasPrefix("evt_"))
            #expect(event.session.isEmpty == false)
            #expect(event.type.isEmpty == false)
            #expect(event.source.isEmpty == false)
        }
    }

    @Test func emittedEnvelopeCarriesTheSchemaVersion() throws {
        let event = ReticleEventEnvelope(
            id: "evt_0000000000000001",
            ts: 1,
            session: "s",
            target: nil,
            source: "action",
            type: "action.trace"
        )
        #expect(event.schemaVersion == 1)

        let data = try JSONEncoder().encode(event)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["schemaVersion"] as? Int == 1)
    }

    @Test func appendedEventsArePersistedWithTheSchemaVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try EventStore(session: "v", rootDirectory: root, limit: 10)

        let stamped = try store.append(EventPostRequest(source: "action", type: "action.trace"))
        #expect(stamped.schemaVersion == 1)

        // And the persisted JSONL line carries it, so a downstream consumer can
        // read the generation off the wire.
        let line = try String(contentsOf: store.eventsFile, encoding: .utf8)
            .split(separator: "\n").first.map(String.init) ?? ""
        #expect(line.contains("\"schemaVersion\":1"))
    }

    @Test func legacyLinesWithoutSchemaVersionDecodeAsV1() throws {
        // A pre-marker events.jsonl line must still load (default to v1) rather
        // than being skipped as corrupt by the tolerant loader.
        let legacy = #"{"id":"evt_0000000000000009","ts":5,"session":"s","source":"action","type":"action.trace","payload":{},"refs":{}}"#
        let event = try JSONDecoder().decode(ReticleEventEnvelope.self, from: Data(legacy.utf8))
        #expect(event.schemaVersion == 1)
        #expect(event.id == "evt_0000000000000009")
    }
}
