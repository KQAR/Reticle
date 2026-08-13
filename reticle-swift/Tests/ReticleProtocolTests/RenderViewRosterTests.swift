import XCTest
@testable import ReticleProtocol

/// The `ui <view>` roster, against this port — driven by the language-neutral
/// fixture reticle-protocol/fixtures/render-views.cases.json, which the Kotlin
/// suite reads too.
///
/// The CLI advertises ONE list of views for every target, so a view is either
/// rendered here or refused by a reason that names the boundary. What this suite
/// forbids is the third outcome: falling through to `unknownView`, an internal
/// error wearing a user-facing message. `ui outline --target ios` did exactly that
/// — it named no boundary, suggested no path, and read as a broken build rather
/// than as an Android-only projection.
final class RenderViewRosterTests: XCTestCase {

    private struct ViewCase: Decodable {
        var name: String
        var platforms: [String]
        var refusalMentions: [String]?
    }

    private struct Roster: Decodable {
        var views: [ViewCase]
    }

    private func roster() throws -> [ViewCase] {
        // <repo>/reticle-swift/Tests/ReticleProtocolTests/<this file>
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(
            contentsOf: repoRoot.appendingPathComponent("reticle-protocol/fixtures/render-views.cases.json")
        )
        return try JSONDecoder().decode(Roster.self, from: data).views
    }

    private func golden() throws -> Snapshot {
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(
            contentsOf: repoRoot.appendingPathComponent("reticle-protocol/fixtures/snapshot.golden.json")
        )
        return try ReticleJSON.decode(Snapshot.self, from: data)
    }

    func testTheRosterConstantMatchesTheSharedFixture() throws {
        XCTAssertEqual(try roster().map(\.name), Render.roster,
                       "Render.roster and render-views.cases.json are the same list, in the same order")
    }

    func testEveryRosterViewEitherRendersOrNamesItsBoundary() throws {
        let snapshot = try golden()
        for view in try roster() {
            do {
                _ = try Render.view(view.name, snapshot: snapshot, selector: nil)
                XCTAssertTrue(view.platforms.contains("ios"),
                              "'\(view.name)' rendered but the fixture says iOS does not support it")
            } catch let error as Render.RenderError {
                switch error {
                case .unknownView:
                    XCTFail("'\(view.name)' is on the roster and fell through to unknownView — "
                            + "the exact shape docs/boundaries.md forbids")
                case .noSelector, .nodeNotFound:
                    // `node` and `style` need a selector this smoke call does not pass.
                    // They ARE implemented; reaching their own argument error proves it.
                    XCTAssertTrue(view.platforms.contains("ios"), "'\(view.name)' is implemented on iOS")
                case .androidOnly:
                    XCTAssertFalse(view.platforms.contains("ios"),
                                   "'\(view.name)' is refused as Android-only but the fixture lists ios")
                    let text = error.description
                    for mention in view.refusalMentions ?? [] {
                        XCTAssertTrue(text.contains(mention),
                                      "the refusal for '\(view.name)' must mention '\(mention)': \(text)")
                    }
                }
            }
        }
    }

    /// A name off the roster is still an unknown view — the refusal above is for
    /// views the CLI advertises, not a blanket softening of typo handling.
    func testAViewNobodyAdvertisesIsStillUnknown() throws {
        let snapshot = try golden()
        XCTAssertThrowsError(try Render.view("outlines", snapshot: snapshot)) { error in
            guard let error = error as? Render.RenderError, case .unknownView = error else {
                return XCTFail("a typo must stay an unknown view, got \(error)")
            }
        }
    }
}
