import XCTest
@testable import ReticleProtocol

/// The text projections an agent reads (`ui compact`, `ui tree`,
/// `ui tree --semantics`, `ui regions`), driven by the SAME language-neutral
/// fixture the Kotlin suite reads:
/// reticle-protocol/fixtures/snapshot-render.cases.json.
///
/// This is the anti-drift device for the projections an agent looks at most. An
/// Android snapshot renders through `dev.reticle.core.Render` in the Kotlin helper
/// and an iOS one through `Render` here; before the fixture existed the two were
/// pinned only by hand-mirrored unit tests, and `compact` had already drifted that
/// way once — the derivation was shared while the formatting was not.
final class RenderContractTests: XCTestCase {

    private struct Case: Decodable {
        var name: String
        var expect: [String: [String]]
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
            .appendingPathComponent("reticle-protocol/fixtures/snapshot-render.cases.json")
        let data = try Data(contentsOf: fixture)
        return try ReticleJSON.decode(Cases.self, from: data).cases
    }

    private func render(_ view: String, _ snapshot: Snapshot) throws -> [String] {
        try Render.view(view, snapshot: snapshot).components(separatedBy: "\n")
    }

    func testEveryFixtureCaseRendersAsSpecified() throws {
        var failures: [String] = []
        for c in try loadCases() {
            for (view, expect) in c.expect {
                let actual = try render(view, c.snapshot)
                if actual != expect {
                    failures.append(
                        """
                          - \(c.name) [\(view)]
                              expected:
                        \(expect.map { "        \($0)" }.joined(separator: "\n"))
                              actual:
                        \(actual.map { "        \($0)" }.joined(separator: "\n"))
                        """
                    )
                }
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "text projections diverged from the fixture:\n" + failures.joined(separator: "\n")
        )
    }

    /// The screen-level lines are the ones a renderer loses silently: without the
    /// focus line a screen behind a system prompt reads as ordinary, without the
    /// keyboard line covered items read as tappable, and without the fold footer a
    /// token-cheap view reads as the whole tree.
    func testFixtureCoversTheFactsNoNodeCarries() throws {
        let rendered = try loadCases().flatMap { $0.expect.values.flatMap { $0 } }
        XCTAssertTrue(rendered.contains { $0.hasPrefix("window: UNFOCUSED") })
        XCTAssertTrue(rendered.contains { $0.hasPrefix("keyboard: visible") })
        XCTAssertTrue(rendered.contains { $0.hasPrefix("keyboard: hidden") })
        XCTAssertTrue(rendered.contains { $0.contains("anonymous layer(s) folded") })
        XCTAssertTrue(rendered.contains { $0.hasPrefix("window ") && $0.hasSuffix("[top]") })
        XCTAssertTrue(rendered.contains { $0.contains("occluded-by:keyboard") })
    }

    /// Each of these is a boundary from docs/boundaries.md whose whole purpose is to
    /// be VISIBLE — a marker that stops rendering turns an unreachable thing back
    /// into a silent absence.
    func testFixtureCoversEveryBoundaryMarker() throws {
        let rendered = try loadCases().flatMap { $0.expect.values.flatMap { $0 } }
        for marker in [
            "dom:unavailable",
            "dom:unsupported-kernel",
            "pixels:unavailable",
            "screencap:blank",
            "wheel:selection-only",
            "wheel:opaque",
            "scroll:",
            // The three frame walls are one marker family and must stay three: they
            // ask a caller for opposite moves (coordinates / fix the page / retry),
            // and collapsing any two of them is the defect this family exists to fix.
            "iframe:cross-origin",
            "iframe:sandboxed",
            "iframe:not-loaded",
            "geometry:approx",
        ] {
            XCTAssertTrue(rendered.contains { $0.contains(marker) }, "no case renders '\(marker)'")
        }
    }

    func testFixtureCoversBothPlatforms() throws {
        let cases = try loadCases()
        XCTAssertTrue(cases.contains { $0.snapshot.platform == "android" })
        XCTAssertTrue(cases.contains { $0.snapshot.platform == "ios" })
    }
}
