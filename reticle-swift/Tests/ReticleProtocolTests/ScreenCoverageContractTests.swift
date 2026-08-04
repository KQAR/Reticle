import XCTest
@testable import ReticleProtocol

/// The blind-agent coverage self-report — `ui coverage` and the verdict every
/// coordinate tap carries — driven by the SAME language-neutral fixture the Kotlin
/// suite reads: reticle-protocol/fixtures/screen-coverage.cases.json.
///
/// The anti-drift device for a number an agent calibrates on. If the iOS host and
/// the Android helper disagree about what "unreachable" means, a `--point` fallback
/// justified on one platform reads as unnecessary on the other.
final class ScreenCoverageContractTests: XCTestCase {

    private struct ExpectedPoint: Decodable {
        var x: Double
        var y: Double
        var covered: Bool
        var reason: String
        var ref: String?
        var selector: String?
        var warning: String
    }

    private struct Case: Decodable {
        var name: String
        var report: [String]
        var points: [ExpectedPoint]
        var snapshot: Snapshot
    }

    private struct Cases: Decodable {
        var cases: [Case]
    }

    private func loadCases() throws -> [Case] {
        // <repo>/reticle-swift/Tests/ReticleProtocolTests/<this file>
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repoRoot
            .appendingPathComponent("reticle-protocol/fixtures/screen-coverage.cases.json")
        let data = try Data(contentsOf: fixture)
        return try ReticleJSON.decode(Cases.self, from: data).cases
    }

    func testEveryFixtureCaseReportsAsSpecified() throws {
        var failures: [String] = []
        for c in try loadCases() {
            let actual = Render.coverage(c.snapshot).components(separatedBy: "\n")
            if actual != c.report {
                failures.append("""
                  - \(c.name) [report]
                      expected:
                \(c.report.map { "        \($0)" }.joined(separator: "\n"))
                      actual:
                \(actual.map { "        \($0)" }.joined(separator: "\n"))
                """)
            }
            for point in c.points {
                let verdict = ScreenCoverage.at(c.snapshot, x: point.x, y: point.y)
                let got = [
                    String(verdict.covered), verdict.reason,
                    verdict.ref ?? "-", verdict.selector ?? "-", verdict.warning(),
                ]
                let want = [
                    String(point.covered), point.reason,
                    point.ref ?? "-", point.selector ?? "-", point.warning,
                ]
                if got != want {
                    failures.append("""
                      - \(c.name) [point \(Rect.whole(point.x)),\(Rect.whole(point.y))]
                          expected: \(want)
                          actual:   \(got)
                    """)
                }
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "coverage diverged from the fixture:\n" + failures.joined(separator: "\n")
        )
    }

    func testACheckThatCouldNotRunSaysSoInsteadOfGoingMissing() {
        let verdict = ScreenCoverage.unavailable(x: 10, y: 20, why: "the runtime was unreachable")
        XCTAssertEqual(verdict.reason, ScreenCoverage.reasonUnavailable)
        XCTAssertEqual(
            verdict.warning(),
            "could not check whether a selector covers (10,20) — the runtime was unreachable"
        )
        // The wire keys the host prints from, spelled once for both platforms.
        let wire = verdict.jsonObject
        for key in ["x", "y", "covered", "reason", "detail", "warning"] {
            XCTAssertNotNil(wire[key], "the coverage wire object dropped '\(key)'")
        }
    }

    func testAnEmptyScreenIsHundredPercentRatherThanUndefined() {
        let root = Node(
            ref: "r0", kind: .application, typeName: "UIApplication", role: "application"
        )
        let snapshot = Snapshot(
            capturedAtMillis: 0,
            platform: "ios",
            screen: ScreenInfo(size: Size(width: 64, height: 64), density: 3),
            rootRef: "r0",
            nodes: ["r0": root]
        )
        let report = ScreenCoverage.of(snapshot)
        XCTAssertEqual(report.touchRelevantCells, 0)
        XCTAssertEqual(report.addressablePercent, 100)
        XCTAssertTrue(report.render().contains("no touch-relevant cells on this screen"))
    }

    func testALaterDrawnCoverDecidesTheVerdictAtItsOwnPoint() {
        func node(_ ref: String, _ testId: String) -> Node {
            Node(
                ref: ref, parentRef: "w1", kind: .view, typeName: "UIView", role: "view",
                testId: testId, frame: Rect(x: 0, y: 0, width: 64, height: 64),
                isInteractive: true
            )
        }
        let window = Node(
            ref: "w1", parentRef: "r0", kind: .window, typeName: "UIWindow", role: "window",
            frame: Rect(x: 0, y: 0, width: 64, height: 64), children: ["under", "over"]
        )
        let root = Node(
            ref: "r0", kind: .application, typeName: "UIApplication", role: "application",
            children: ["w1"]
        )
        let nodes = [root, window, node("under", "under"), node("over", "over")]
        let snapshot = Snapshot(
            capturedAtMillis: 0,
            platform: "ios",
            screen: ScreenInfo(size: Size(width: 64, height: 64), density: 3),
            rootRef: "r0",
            nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.ref, $0) })
        )
        XCTAssertEqual(ScreenCoverage.at(snapshot, x: 32, y: 32).ref, "over")
    }
}
