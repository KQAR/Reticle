import Foundation
import Testing
import ReticleProtocol
@testable import ReticleHostCore
@testable import ReticleNetworkLane

/// Full JSON Schema validation of what the Swift side actually emits, against
/// the authoritative `reticle-protocol/schema/*.json`. The Kotlin contract test
/// does this with networknt; before this suite the Swift side only compared
/// field-name sets, so a type/enum/nesting drift (e.g. a MetadataValue tag or a
/// number-vs-integer slip) went unnoticed. Now both implementations are pinned
/// to the same schemas at the value level.
@Suite("Schema validation (Swift emitters vs reticle-protocol)")
struct SchemaValidationTests {
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReticleHostCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // reticle-host
            .deletingLastPathComponent()   // repo root
    }

    private func schema(_ name: String) -> URL {
        repoRoot().appendingPathComponent("reticle-protocol/schema/\(name)")
    }

    private func fixture(_ name: String) -> URL {
        repoRoot().appendingPathComponent("reticle-protocol/fixtures/\(name)")
    }

    // MARK: - snapshot.schema.json

    private func sampleSnapshot() -> Snapshot {
        let root = Node(ref: "r0", kind: .application, typeName: "UIApplication", role: "application", children: ["r1"])
        let window = Node(ref: "r1", parentRef: "r0", kind: .window, typeName: "UIWindow", role: "window",
                          frame: Rect(x: 0, y: 0, width: 393, height: 852), children: ["r2", "r3"])
        let button = Node(ref: "r2", parentRef: "r1", kind: .view, typeName: "UIButton", role: "button",
                          contentDescription: "Continue", text: "Continue", testId: "checkout.payButton",
                          frame: Rect(x: 24, y: 720, width: 345, height: 50), isInteractive: true,
                          custom: ["alpha": .real(1.0), "backgroundColor": .text("#FF007AFF"), "tag": .integer(7), "flag": .bool(true)])
        let swiftui = Node(ref: "r3", parentRef: "r1", kind: .axElement, typeName: "SwiftUI.Button", role: "button",
                           contentDescription: "Sign In", text: "Sign In", testId: "login.signIn",
                           frame: Rect(x: 24, y: 640, width: 345, height: 44), isInteractive: true,
                           custom: ["observationBackend": .text("native-accessibility")])
        return Snapshot(
            capturedAtMillis: 1719400000000,
            platform: "ios",
            screen: ScreenInfo(size: Size(width: 393, height: 852), density: 3.0, interfaceStyle: "dark"),
            rootRef: "r0",
            nodes: ["r0": root, "r1": window, "r2": button, "r3": swiftui]
        )
    }

    @Test func swiftEmittedSnapshotSatisfiesSnapshotSchema() throws {
        let data = try ReticleJSON.encodeWire(sampleSnapshot())
        let errors = try JSONSchemaValidator.validate(instanceData: data, schemaURL: schema("snapshot.schema.json"))
        #expect(errors.isEmpty, "snapshot schema violations: \(errors)")
    }

    @Test func snapshotWithKeyboardAndRegionsSatisfiesSchema() throws {
        var snap = sampleSnapshot()
        snap.screen.keyboard = KeyboardInfo(visible: true, frame: Rect(x: 0, y: 700, width: 393, height: 152))
        let data = try ReticleJSON.encodeWire(snap)
        let errors = try JSONSchemaValidator.validate(instanceData: data, schemaURL: schema("snapshot.schema.json"))
        #expect(errors.isEmpty, "snapshot schema violations: \(errors)")
    }

    @Test func iosGoldenSnapshotSatisfiesSchemaOnTheSwiftSide() throws {
        // The Kotlin test validates this golden too; do it on the Swift side so a
        // Swift-only reshape of the shared fixture cannot slip past CI.
        let data = try Data(contentsOf: fixture("ios-snapshot.golden.json"))
        let errors = try JSONSchemaValidator.validate(instanceData: data, schemaURL: schema("snapshot.schema.json"))
        #expect(errors.isEmpty, "ios golden snapshot schema violations: \(errors)")
    }

    // MARK: - network-event-payload.schema.json

    @Test func emittedNetworkPayloadSatisfiesPayloadSchema() throws {
        var payload = NetworkEventPayload(
            requestId: "r", scheme: "https", method: "POST", url: "https://h/x",
            host: "h", port: 443, path: "/x", startMillis: 1, tunnel: false, mitm: true
        )
        payload.endMillis = 5
        payload.status = 200
        payload.requestHeaders = ["Accept": "application/json"]
        payload.responseHeaders = ["Content-Type": "application/json"]
        payload.requestBodyBytes = 10
        payload.responseBodyBytes = 20
        payload.requestBodyTruncated = false
        payload.responseBodyTruncated = true
        payload.mocked = true
        payload.mockRuleId = "rule"
        payload.mockValueId = "value"

        let data = try JSONSerialization.data(withJSONObject: payload.json.mapValues(\.anyValue))
        let errors = try JSONSchemaValidator.validate(instanceData: data, schemaURL: schema("network-event-payload.schema.json"))
        #expect(errors.isEmpty, "network payload schema violations: \(errors)")
    }

    @Test func networkPayloadGoldenFixturesSatisfySchema() throws {
        for name in ["network-request-event", "network-response-event", "network-error-event"] {
            let event = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture("\(name).golden.json"))) as? [String: Any] ?? [:]
            let payload = try JSONSerialization.data(withJSONObject: event["payload"] ?? [:])
            let errors = try JSONSchemaValidator.validate(instanceData: payload, schemaURL: schema("network-event-payload.schema.json"))
            #expect(errors.isEmpty, "\(name) payload schema violations: \(errors)")
        }
    }

    // MARK: - event.schema.json

    @Test func eventEnvelopeGoldenFixturesSatisfySchema() throws {
        for name in ["network-request-event", "network-response-event", "network-error-event", "action-trace-event"] {
            let data = try Data(contentsOf: fixture("\(name).golden.json"))
            let errors = try JSONSchemaValidator.validate(instanceData: data, schemaURL: schema("event.schema.json"))
            #expect(errors.isEmpty, "\(name) envelope schema violations: \(errors)")
        }
    }
}

/// Self-tests for the validator itself: prove it CATCHES the drift it exists to
/// catch, so a green schema suite means the schemas really held — not that the
/// validator silently accepts everything.
@Suite("JSON schema validator self-tests")
struct JSONSchemaValidatorSelfTests {
    private func snapshotSchema() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("reticle-protocol/schema/snapshot.schema.json")
    }

    @Test func rejectsWrongMetadataValueType() throws {
        // _type says "int" but value is a string — the exact allOf/if/then drift
        // the field-name comparison could never catch.
        let bad = """
        {"schemaVersion":1,"capturedAtMillis":1,"platform":"ios",
         "screen":{"size":{"width":1,"height":1},"density":1},
         "rootRef":"r0",
         "nodes":{"r0":{"ref":"r0","kind":"view","typeName":"X",
           "custom":{"k":{"_type":"int","value":"not-an-int"}}}}}
        """
        let errors = try JSONSchemaValidator.validate(instanceData: Data(bad.utf8), schemaURL: snapshotSchema())
        #expect(!errors.isEmpty)
    }

    @Test func rejectsUnknownNodeKindEnum() throws {
        let bad = """
        {"schemaVersion":1,"capturedAtMillis":1,"platform":"ios",
         "screen":{"size":{"width":1,"height":1},"density":1},
         "rootRef":"r0",
         "nodes":{"r0":{"ref":"r0","kind":"teleport","typeName":"X"}}}
        """
        let errors = try JSONSchemaValidator.validate(instanceData: Data(bad.utf8), schemaURL: snapshotSchema())
        #expect(errors.contains { $0.contains("enum") })
    }

    @Test func rejectsMissingRequiredAndAdditionalProperty() throws {
        // rootRef missing; an undeclared top-level property present.
        let bad = """
        {"schemaVersion":1,"capturedAtMillis":1,"platform":"ios",
         "screen":{"size":{"width":1,"height":1},"density":1},
         "nodes":{},"surpriseField":true}
        """
        let errors = try JSONSchemaValidator.validate(instanceData: Data(bad.utf8), schemaURL: snapshotSchema())
        #expect(errors.contains { $0.contains("rootRef") })
        #expect(errors.contains { $0.contains("surpriseField") })
    }

    @Test func rejectsWrongSchemaVersionConst() throws {
        let bad = """
        {"schemaVersion":2,"capturedAtMillis":1,"platform":"ios",
         "screen":{"size":{"width":1,"height":1},"density":1},
         "rootRef":"r0","nodes":{}}
        """
        let errors = try JSONSchemaValidator.validate(instanceData: Data(bad.utf8), schemaURL: snapshotSchema())
        #expect(errors.contains { $0.contains("const") })
    }

    @Test func acceptsAValidMinimalSnapshot() throws {
        let good = """
        {"schemaVersion":1,"capturedAtMillis":1,"platform":"ios",
         "screen":{"size":{"width":1,"height":1},"density":1},
         "rootRef":"r0",
         "nodes":{"r0":{"ref":"r0","kind":"view","typeName":"X"}}}
        """
        let errors = try JSONSchemaValidator.validate(instanceData: Data(good.utf8), schemaURL: snapshotSchema())
        #expect(errors.isEmpty, "unexpected violations: \(errors)")
    }
}
