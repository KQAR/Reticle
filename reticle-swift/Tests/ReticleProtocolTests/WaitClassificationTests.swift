import XCTest
@testable import ReticleProtocol

/// `act wait`'s outcome table, driven by the SAME language-neutral fixture the
/// Kotlin suite reads: reticle-protocol/fixtures/wait-classification.cases.json.
///
/// This is the anti-drift device for the feature. The Android poll loop lives in
/// the Kotlin helper and the iOS one in the Swift host, so without one shared
/// table the two would answer differently over time — which is exactly what
/// happened to `scroll-to`'s settle logic, whose Kotlin and Swift halves are two
/// hand-written implementations of one idea.
final class WaitClassificationTests: XCTestCase {

    private struct Expect: Decodable {
        var outcome: WaitOutcome
        var reasons: [String] = []
        var caveats: [String] = []

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            outcome = try c.decode(WaitOutcome.self, forKey: .outcome)
            reasons = try c.decodeIfPresent([String].self, forKey: .reasons) ?? []
            caveats = try c.decodeIfPresent([String].self, forKey: .caveats) ?? []
        }

        enum CodingKeys: String, CodingKey { case outcome, reasons, caveats }
    }

    private struct Case: Decodable {
        var name: String
        var predicate: WaitPredicate
        var probe: WaitProbe
        var quiet: Bool
        var expect: Expect
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
            .appendingPathComponent("reticle-protocol/fixtures/wait-classification.cases.json")
        let data = try Data(contentsOf: fixture)
        return try JSONDecoder().decode(Cases.self, from: data).cases
    }

    func testEveryFixtureCaseClassifiesAsSpecified() throws {
        var failures: [String] = []
        for c in try loadCases() {
            let actual = WaitVerdict.classify(c.predicate, c.probe, quiet: c.quiet)
            if actual.outcome != c.expect.outcome
                || actual.reasons != c.expect.reasons
                || actual.caveats != c.expect.caveats {
                failures.append(
                    """
                      - \(c.name)
                          expected outcome=\(c.expect.outcome) reasons=\(c.expect.reasons) caveats=\(c.expect.caveats)
                          actual   outcome=\(actual.outcome) reasons=\(actual.reasons) caveats=\(actual.caveats)
                    """
                )
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "wait classification disagreed with the fixture table:\n" + failures.joined(separator: "\n")
        )
    }

    func testFixtureCoversEveryOutcomeAndReason() throws {
        // Guards the guard: a table that stopped exercising a branch would pass the
        // test above while proving nothing.
        let cases = try loadCases()
        XCTAssertGreaterThanOrEqual(cases.count, 20, "expected a broad table, found \(cases.count)")
        let outcomes = Set(cases.map { $0.expect.outcome })
        XCTAssertEqual(outcomes, Set(WaitOutcome.allCases), "every outcome must appear in the table")
        let reasons = Set(cases.flatMap { $0.expect.reasons })
        for required in [
            WaitVerdict.reasonTreeStillChanging,
            WaitVerdict.reasonWindowUnfocused,
            WaitVerdict.reasonDomUnavailable,
            WaitVerdict.reasonDomUnsupportedKernel,
            WaitVerdict.reasonSelectorAmbiguous,
        ] {
            XCTAssertTrue(reasons.contains(required), "no fixture case exercises reason '\(required)'")
        }
        let caveats = Set(cases.flatMap { $0.expect.caveats })
        XCTAssertTrue(
            caveats.contains { $0.hasPrefix(WaitVerdict.caveatOccludedPrefix) },
            "no fixture case exercises an occlusion caveat"
        )
        XCTAssertTrue(caveats.contains(WaitVerdict.caveatMayBeUnbound))
        XCTAssertTrue(
            caveats.contains(WaitVerdict.caveatResolvedNotVisible),
            "no fixture case exercises the resolvable-but-invisible caveat — the exact case "
                + "the dropped isVisible-based proposal got wrong"
        )
    }

    func testTheSuccessTestIsResolutionNotVisibility() {
        // Pins the design correction that made this feature acceptable at all.
        let invisibleButTargetable = WaitProbe(
            resolved: true,
            source: "semantic:testId",
            visible: false,
            digest: "a"
        )
        let appear = WaitPredicate(kind: .appear, selector: Selector(testId: "checkout.status"))
        let appearVerdict = WaitVerdict.classify(appear, invisibleButTargetable, quiet: true)
        XCTAssertEqual(appearVerdict.outcome, .resolved, "an invisible but resolvable node HAS appeared")
        XCTAssertEqual(appearVerdict.caveats, [WaitVerdict.caveatResolvedNotVisible])

        let gone = WaitPredicate(kind: .gone, selector: Selector(testId: "checkout.status"))
        XCTAssertEqual(
            WaitVerdict.classify(gone, invisibleButTargetable, quiet: true).outcome,
            .absent,
            "an invisible but resolvable node is NOT gone"
        )
    }

    func testAnUnknowableIsNeverAnAbsent() {
        let predicate = WaitPredicate(kind: .appear, selector: Selector(testId: "x"))
        for probe in [
            WaitProbe(digest: "a", windowFocused: false),
            WaitProbe(digest: "a", scrollTravel: ["@l scroll:down"]),
            WaitProbe(digest: "a", ambiguous: true),
        ] {
            XCTAssertEqual(
                WaitVerdict.classify(predicate, probe, quiet: true).outcome,
                .unknowable,
                "this probe must not be reported as an honest negative"
            )
        }
        XCTAssertEqual(
            WaitVerdict.classify(predicate, WaitProbe(digest: "a"), quiet: true).outcome,
            .absent
        )
    }

    func testScheduleBacksOffAsTheBudgetBurns() {
        XCTAssertEqual(WaitSchedule.delayMs(elapsedMs: 0), 100)
        XCTAssertEqual(WaitSchedule.delayMs(elapsedMs: 1_999), 100)
        XCTAssertEqual(WaitSchedule.delayMs(elapsedMs: 2_000), 250)
        XCTAssertEqual(WaitSchedule.delayMs(elapsedMs: 4_999), 250)
        XCTAssertEqual(WaitSchedule.delayMs(elapsedMs: 5_000), 500)
        XCTAssertEqual(WaitSchedule.delayMs(elapsedMs: 60_000), 500)
    }

    func testPredicateDescribeEchoesWhatWasAsked() {
        XCTAssertEqual(
            WaitPredicate(kind: .appear, selector: Selector(testId: "cart.total")).describe(),
            "appear testId=cart.total"
        )
        XCTAssertEqual(
            WaitPredicate(kind: .gone, selector: Selector(cssSelector: "#toast")).describe(),
            "gone css=#toast"
        )
        XCTAssertEqual(
            WaitPredicate(
                kind: .text,
                selector: Selector(resourceId: "status"),
                textContains: "Paid"
            ).describe(),
            "text resourceId=status contains \"Paid\""
        )
        XCTAssertEqual(WaitPredicate(kind: .idle).describe(), "idle")
    }
}
