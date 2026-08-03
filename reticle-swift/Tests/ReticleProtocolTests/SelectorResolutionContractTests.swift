import XCTest
@testable import ReticleProtocol

// Disambiguate from ObjC's `Selector` (Foundation, pulled in by XCTest) — here we
// always mean the protocol's target selector.
private typealias TargetSelector = ReticleProtocol.Selector

/// The action path's selector-resolution table, driven by the SAME
/// language-neutral fixture the Kotlin suite reads:
/// reticle-protocol/fixtures/selector-resolution.cases.json.
///
/// This is the anti-drift device for where a tap lands. The Android resolver is
/// Kotlin (`reticle-helper`'s `SelectorResolver`) and the iOS one is this
/// package's `SelectorResolution`; before the fixture existed they had drifted in
/// seven ways, including one that made resolution nondeterministic per process on
/// this side. Every case here runs against the other implementation too.
final class SelectorResolutionContractTests: XCTestCase {

    private struct Expect: Decodable {
        var point: Point?
        var source: String?
        var ref: String?
        var miss: Bool?
        var error: String?
    }

    private struct Case: Decodable {
        var name: String
        var selector: TargetSelector
        var expect: Expect
    }

    private struct Fixture: Decodable {
        var snapshot: Snapshot
        var cases: [Case]
    }

    private func loadFixture() throws -> Fixture {
        // <repo>/reticle-swift/Tests/ReticleProtocolTests/<this file>
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repoRoot
            .appendingPathComponent("reticle-protocol/fixtures/selector-resolution.cases.json")
        return try ReticleJSON.decode(Fixture.self, from: try Data(contentsOf: fixture))
    }

    func testEveryFixtureCaseResolvesAsSpecified() throws {
        let fixture = try loadFixture()
        let semantic = SemanticTree.build(from: fixture.snapshot)
        var failures: [String] = []

        for c in fixture.cases {
            let outcome: String
            do {
                let resolved = try SelectorResolution.resolve(
                    snapshot: fixture.snapshot, semantic: semantic, selector: c.selector
                )
                if let r = resolved {
                    outcome = "\(r.source) @\(fmt(r.point)) ref=\(r.ref ?? "nil")"
                } else {
                    outcome = "miss"
                }
            } catch is SelectorResolution.RegionMiss {
                outcome = "error:regionMiss"
            } catch is Render.AmbiguousLabel {
                outcome = "error:ambiguousLabel"
            } catch is UnsupportedCssSelector {
                // A construct the matcher does not implement is a REFUSAL, never a
                // miss — see the Kotlin twin.
                outcome = "error:unsupportedCss"
            }

            let expected = expectation(c.expect)
            if outcome != expected {
                failures.append("  - \(c.name)\n      expected \(expected)\n      actual   \(outcome)")
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "selector resolution disagreed with the shared fixture:\n" + failures.joined(separator: "\n")
        )
    }

    /// Resolution must not depend on dictionary iteration order. The fixture has
    /// two nodes sharing `dup.button`, so a hash-order lookup answers differently
    /// across processes — and a test inside one process would not catch it.
    /// Re-decoding the snapshot gives the dictionary a fresh internal layout.
    func testDuplicateIdResolutionIsStableAcrossDecodes() throws {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repoRoot
            .appendingPathComponent("reticle-protocol/fixtures/selector-resolution.cases.json"))

        for _ in 0..<50 {
            let fixture = try ReticleJSON.decode(Fixture.self, from: data)
            let semantic = SemanticTree.build(from: fixture.snapshot)
            let resolved = try SelectorResolution.resolve(
                snapshot: fixture.snapshot, semantic: semantic, selector: TargetSelector(testId: "dup.button")
            )
            XCTAssertEqual(resolved?.ref, "n2", "duplicate testId must always resolve to the first in document order")
        }
    }

    private func expectation(_ e: Expect) -> String {
        if let error = e.error { return "error:\(error)" }
        if e.miss == true { return "miss" }
        guard let point = e.point, let source = e.source else { return "<malformed case>" }
        return "\(source) @\(fmt(point)) ref=\(e.ref ?? "nil")"
    }

    private func fmt(_ p: Point) -> String {
        "\(String(format: "%.1f", p.x)),\(String(format: "%.1f", p.y))"
    }
}
