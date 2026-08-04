import XCTest
@testable import ReticleProtocol

/// Where a tap can actually land, driven by the SAME language-neutral fixture the
/// Kotlin suite reads: reticle-protocol/fixtures/tap-reach.cases.json.
///
/// The anti-drift device for an aim. A tap refused on one platform and dispatched
/// into empty space on the other is the worst kind of difference: the flow "works"
/// on one device and silently does nothing on the other.
final class TapReachContractTests: XCTestCase {

    private struct ExpectedTarget: Decodable {
        var ref: String
        /// "x,y", or absent when the fixture expects a refusal.
        var point: String?
        var adjusted: Bool?
        var reason: String?
        var by: String?
        var explain: String?
    }

    private struct Case: Decodable {
        var name: String
        var targets: [ExpectedTarget]
        var snapshot: Snapshot
    }

    private struct Cases: Decodable {
        var cases: [Case]
    }

    private func loadCases() throws -> [Case] {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repoRoot.appendingPathComponent("reticle-protocol/fixtures/tap-reach.cases.json")
        return try ReticleJSON.decode(Cases.self, from: Data(contentsOf: fixture)).cases
    }

    func testEveryFixtureTargetResolvesWhereTheFixtureSays() throws {
        var failures: [String] = []
        for c in try loadCases() {
            for target in c.targets {
                guard let reach = TapReach.of(c.snapshot, ref: target.ref) else {
                    failures.append("  - \(c.name): \(target.ref) is not in the fixture snapshot")
                    continue
                }
                let got = [
                    reach.point.map { "\(Rect.whole($0.x)),\(Rect.whole($0.y))" } ?? "-",
                    String(reach.adjusted),
                    reach.reason ?? "-",
                    reach.by ?? "-",
                    reach.adjusted ? reach.explain(target.ref) : "-",
                ]
                let want = [
                    target.point ?? "-",
                    String(target.adjusted ?? false),
                    target.reason ?? "-",
                    target.by ?? "-",
                    target.explain ?? "-",
                ]
                if got != want {
                    failures.append("""
                      - \(c.name) [\(target.ref)]
                          expected: \(want)
                          actual:   \(got)
                    """)
                }
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "tap reach diverged from the fixture:\n" + failures.joined(separator: "\n")
        )
    }

    func testTheFixturePinsBothRefusalsAndTheQuietCase() throws {
        let targets = try loadCases().flatMap(\.targets)
        XCTAssertTrue(
            targets.contains { $0.reason == TapReach.unreachableOffScreen },
            "no case pins an off-screen refusal"
        )
        XCTAssertTrue(
            targets.contains { $0.reason == TapReach.unreachableClipped },
            "no case pins a clipped refusal"
        )
        XCTAssertTrue(targets.contains { $0.adjusted == true }, "no case pins an adjusted aim")
        XCTAssertTrue(
            targets.contains { $0.adjusted != true }, "no case pins a tap that needed no adjustment"
        )
    }
}
