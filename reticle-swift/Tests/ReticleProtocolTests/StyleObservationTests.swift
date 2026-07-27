import XCTest
@testable import ReticleProtocol

/// The style projection's output table, driven by the SAME language-neutral
/// fixture the Kotlin suite reads:
/// reticle-protocol/fixtures/style-observation.cases.json.
///
/// This is the anti-drift device for the feature. An Android snapshot renders
/// through the Kotlin helper and an iOS one through this Swift code, so a unit
/// conversion or line format changed on one side only would silently give two
/// answers for one screen — the failure this repo has already had with the two
/// `compact` renderers.
///
/// The conversions worth naming, because getting either wrong is silent: an
/// Android length is physical pixels and divides by density, while a UIKit length
/// is points and must NOT be divided again; and sp needs `fontScale`, whose
/// absence is reported rather than assumed to be 1.0.
final class StyleObservationTests: XCTestCase {

    private struct Case: Decodable {
        var name: String
        var snapshot: Snapshot
        var expect: [String]
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
            .appendingPathComponent("reticle-protocol/fixtures/style-observation.cases.json")
        let data = try Data(contentsOf: fixture)
        return try ReticleJSON.decode(Cases.self, from: data).cases
    }

    func testEveryFixtureCaseRendersAsSpecified() throws {
        var failures: [String] = []
        for c in try loadCases() {
            let actual = StyleObservation.from(c.snapshot).render()
                .components(separatedBy: "\n")
            if actual != c.expect {
                failures.append(
                    """
                      - \(c.name)
                          expected:
                    \(c.expect.map { "        " + $0 }.joined(separator: "\n"))
                          actual:
                    \(actual.map { "        " + $0 }.joined(separator: "\n"))
                    """
                )
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "style projection diverged from the fixture:\n" + failures.joined(separator: "\n")
        )
    }

    func testFixtureCoversBothUnitSystemsAndAGap() throws {
        // A fixture that lost its iOS case would let the density-double-scaling bug
        // back in unnoticed, and one with no gap case would let the "unreadable
        // property looks absent" regression through. Assert the coverage itself.
        let cases = try loadCases()
        XCTAssertTrue(cases.contains { $0.snapshot.platform == "android" }, "no android case")
        XCTAssertTrue(cases.contains { $0.snapshot.platform == "ios" }, "no iOS case")
        XCTAssertTrue(
            cases.contains { c in c.snapshot.nodes.values.contains { !$0.styleGaps.isEmpty } },
            "no case exercises styleGaps"
        )
        XCTAssertTrue(
            cases.contains { $0.snapshot.screen.fontScale == nil },
            "no case exercises an unprobed fontScale"
        )
    }

    func testStyleChannelsIsTheAllowlistOfWhatCountsAsStyle() {
        // `tag` lives in `custom` but carries no channel, so it must not appear in
        // the projection: without this rule the style view would slowly become a
        // dump of every scalar the agent happens to reflect.
        let node = Node(
            ref: "r1",
            kind: .view,
            typeName: "UILabel",
            custom: ["textSize": .real(17.0), "tag": .text("not-style")],
            styleChannels: ["textSize": .viewField]
        )
        let snapshot = Snapshot(
            capturedAtMillis: 0,
            platform: "ios",
            screen: ScreenInfo(size: Size(width: 393, height: 852), density: 3.0, fontScale: 1.0),
            rootRef: "r1",
            nodes: ["r1": node]
        )
        let item = StyleObservation.from(snapshot).items.first
        XCTAssertEqual(item?.attributes.map { $0.name }, ["textSize"])
    }

    func testUnknownPropertyNamesRenderVerbatimInsteadOfBeingConverted() {
        // A new capture surface must degrade to "shown as captured", never to a
        // wrong conversion — the reason the unit table maps names to kinds and
        // defaults to `opaque`.
        XCTAssertEqual(StyleUnits.unitOf("someNewProperty"), .opaque)
        let units = StyleUnits(
            platform: "android",
            screen: ScreenInfo(size: Size(width: 1080, height: 2400), density: 3.0, fontScale: 1.0)
        )
        XCTAssertEqual(units.render("someNewProperty", .real(13.5)), "13.5")
    }
}
