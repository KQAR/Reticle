import XCTest
@testable import ReticleProtocol

/// The blind-agent coverage self-report — `ui coverage` and the verdict every
/// coordinate tap carries — driven by reticle-protocol/fixtures/screen-coverage.cases.json.
///
/// `ScreenCoverage` is the only implementation and judges both platforms' taps in
/// the host, so this fixture is no longer an anti-drift device between two ports;
/// it pins the sentences an agent calibrates on, with cases from both platforms.
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

    /// One tap, and who the fixture says receives it. An entry with no `reason` is
    /// the case worth pinning hardest: nothing is in the way, so the tap must stay
    /// quiet.
    private struct ExpectedObstruction: Decodable {
        var x: Double
        var y: Double
        var targetRef: String?
        var reason: String?
        var ref: String?
        var warning: String?
    }

    private struct Case: Decodable {
        var name: String
        var report: [String]
        var points: [ExpectedPoint]
        var obstructions: [ExpectedObstruction]?
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
            for expected in c.obstructions ?? [] {
                let actual = ScreenCoverage.obstruction(
                    c.snapshot, x: expected.x, y: expected.y, targetRef: expected.targetRef
                )
                let got = [
                    actual?.reason ?? "-", actual?.ref ?? "-",
                    actual?.warning(x: expected.x, y: expected.y) ?? "-",
                ]
                let want = [expected.reason ?? "-", expected.ref ?? "-", expected.warning ?? "-"]
                if got != want {
                    failures.append("""
                      - \(c.name) [obstruction \(Rect.whole(expected.x)),\(Rect.whole(expected.y)) \
                    target=\(expected.targetRef ?? "-")]
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

    func testTheFixturePinsEveryWayATouchCanBeTakenFromItsTarget() throws {
        let reasons = try loadCases().flatMap { ($0.obstructions ?? []).map(\.reason) }
        for reason in [
            ScreenCoverage.obstructedByKeyboard,
            ScreenCoverage.obstructedByWindow,
            ScreenCoverage.obstructedByNode,
        ] {
            XCTAssertTrue(reasons.contains(reason), "no case pins '\(reason)'")
        }
        XCTAssertTrue(reasons.contains(nil), "no case pins a tap with nothing in the way")
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

    func testTheFixtureCoversEveryVerdictTheReportCanReach() throws {
        // Each of these is a DIFFERENT response by the agent reading it: a covered
        // point means drop the coordinate, a boundary means keep it, inert means
        // look again, nothing-captured means the screen moved. A verdict that stops
        // being pinned collapses into whichever neighbour still is.
        let cases = try loadCases()
        let reasons = cases.flatMap { $0.points.map(\.reason) }
        for reason in [
            ScreenCoverage.reasonAddressable, ScreenCoverage.reasonCrossOrigin,
            ScreenCoverage.reasonContainerOnly, ScreenCoverage.reasonNotInteractive,
            ScreenCoverage.reasonNothingCaptured, ScreenCoverage.reasonOffScreen,
            ScreenCoverage.reasonWheel,
        ] {
            XCTAssertTrue(reasons.contains { $0 == reason || $0.hasPrefix("\(reason)(") }, "no case pins '\(reason)'")
        }
        XCTAssertTrue(reasons.contains { $0.hasPrefix("\(ScreenCoverage.reasonDomCapped)(") },
                      "no case pins a capped DOM walk")
        let selectors = cases.flatMap { $0.points.compactMap(\.selector) }
        for flag in ["--test-id", "--css", "--label"] {
            XCTAssertTrue(selectors.contains { $0.hasPrefix(flag) }, "no case pins the '\(flag)' hint")
        }
    }

    func testTheFixtureCoversBothPlatforms() throws {
        let platforms = Set(try loadCases().map(\.snapshot.platform))
        XCTAssertTrue(platforms.contains("android"), "no android case")
        XCTAssertTrue(platforms.contains("ios"), "no iOS case")
    }

    func testAScreenSizedTappableContainerIsNotCoverForThePointsInsideIt() {
        // The measurement that reshaped the rule: an Android `WebView` is focusable,
        // clickable and carries a resource id, so it passes every test a control
        // does while covering the display. Counted as cover, it reported a real
        // hybrid screen as 100% addressable. A selector tap on it lands on ITS
        // centre, which is not where the agent was aiming.
        let web = Node(
            ref: "wv", parentRef: "r0", kind: .view, typeName: "android.webkit.WebView",
            role: "webView", resourceId: "webview", frame: Rect(x: 0, y: 0, width: 100, height: 100),
            isInteractive: true
        )
        let root = Node(
            ref: "r0", kind: .application, typeName: "android.app.Application", role: "application",
            children: ["wv"]
        )
        let snapshot = Snapshot(
            capturedAtMillis: 0,
            platform: "android",
            screen: ScreenInfo(size: Size(width: 100, height: 100), density: 3),
            rootRef: "r0",
            nodes: ["r0": root, "wv": web]
        )
        let verdict = ScreenCoverage.at(snapshot, x: 90, y: 90)
        XCTAssertEqual(verdict.reason, ScreenCoverage.reasonContainerOnly)
        XCTAssertEqual(verdict.ref, "wv")
        XCTAssertTrue(verdict.detail.contains("(50,50)"), "the container's own tap point must be stated")
        let report = ScreenCoverage.of(snapshot)
        XCTAssertEqual(report.addressableCells, 0)
        XCTAssertEqual(report.unreachableCells, report.touchRelevantCells)
    }
}
