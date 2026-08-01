import XCTest
@testable import ReticleProtocol

/// The Swift half of the Kotlin `SchemaVersionGateTest`: a snapshot from a
/// NEWER producer must be refused at ingestion, because the decoder ignores
/// unknown keys and would otherwise fill renamed fields with defaults.
final class SchemaVersionGateTests: XCTestCase {

    private func snapshotData(version: Int) -> Data {
        Data("""
        {
          "schemaVersion": \(version),
          "capturedAtMillis": 0,
          "platform": "ios",
          "screen": {"size": {"width": 400.0, "height": 900.0}, "density": 3.0},
          "rootRef": "r0",
          "nodes": {"r0": {"ref": "r0", "kind": "application", "typeName": "App"}}
        }
        """.utf8)
    }

    func testTheCurrentVersionPassesTheGate() throws {
        let snapshot = try ReticleJSON.decode(Snapshot.self, from: snapshotData(version: Snapshot.schemaVersionValue))
        XCTAssertEqual(try snapshot.requireSupportedSchema().rootRef, "r0")
    }

    func testANewerVersionIsRefusedByName() throws {
        let snapshot = try ReticleJSON.decode(Snapshot.self, from: snapshotData(version: Snapshot.schemaVersionValue + 1))
        XCTAssertThrowsError(try snapshot.requireSupportedSchema()) { error in
            XCTAssertTrue(
                "\(error)".contains("schemaVersion=\(Snapshot.schemaVersionValue + 1)"),
                "the refusal must name the version it saw: \(error)"
            )
        }
    }
}
