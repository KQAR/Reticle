import XCTest
@testable import ReticleProtocol

/// Where a tap actually landed, driven by the shared fixture at
/// `reticle-protocol/fixtures/dom-tap-witness.cases.json` — the Swift half of the pair;
/// the Kotlin half is `DomTapWitnessContractTest` in reticle-core.
final class DomTapWitnessContractTests: XCTestCase {

    private struct ExpectedVerdict: Decodable {
        let token: String
        var landedOn: String?
        var at: String?
        var relation: String = "unknown"

        private enum CodingKeys: String, CodingKey { case token, landedOn, at, relation }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            token = try c.decode(String.self, forKey: .token)
            landedOn = try c.decodeIfPresent(String.self, forKey: .landedOn)
            at = try c.decodeIfPresent(String.self, forKey: .at)
            relation = try c.decodeIfPresent(String.self, forKey: .relation) ?? "unknown"
        }
    }

    private struct Probe: Decodable {
        let ref: String
        var verdict: ExpectedVerdict?
    }

    private struct Case: Decodable {
        let name: String
        let probes: [Probe]
        let snapshot: Snapshot
    }

    private struct Cases: Decodable { let cases: [Case] }

    private func cases() throws -> [Case] {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = repoRoot.appendingPathComponent("reticle-protocol/fixtures/dom-tap-witness.cases.json")
        return try JSONDecoder().decode(Cases.self, from: try Data(contentsOf: file)).cases
    }

    func testEveryFixtureProbeIsJudgedTheWayTheFixtureSays() throws {
        var failures: [String] = []
        for c in try cases() {
            for probe in c.probes {
                let got = DomTapWitness.of(c.snapshot, intendedRef: probe.ref)
                guard let want = probe.verdict else {
                    if got != nil { failures.append("\(c.name): \(probe.ref) expected silence, got \(got!)") }
                    continue
                }
                guard let got else {
                    failures.append("\(c.name): \(probe.ref) expected \(want.token), got silence")
                    continue
                }
                if got.token != want.token || got.landedOn != want.landedOn || got.at != want.at
                    || got.relation.rawValue != want.relation
                {
                    failures.append("\(c.name): \(probe.ref) wanted \(want), got \(got)")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testAReportedMissNamesTheCoordinateAndWhatWasHit() throws {
        let c = try cases().first { $0.probes.contains { $0.verdict?.landedOn == "other" } }
        let message = try XCTUnwrap(DomTapWitness.describe(try XCTUnwrap(c).snapshot, intendedRef: "button"))
        XCTAssertTrue(message.contains("120,270"), message)
        XCTAssertTrue(message.contains("#other"), message)
        XCTAssertTrue(message.contains("#submit"), message)
    }

    func testAnAbsentPointerSaysThePageWasNotTouchedAtAll() throws {
        let c = try cases().first { $0.probes.contains { $0.verdict?.token == DomTapWitness.notReceived } }
        let message = try XCTUnwrap(DomTapWitness.describe(try XCTUnwrap(c).snapshot, intendedRef: "button"))
        XCTAssertTrue(message.contains("no pointer event"), message)
    }
}
