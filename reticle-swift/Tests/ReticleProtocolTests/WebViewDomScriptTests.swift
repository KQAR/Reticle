import XCTest
@testable import ReticleProtocol

/// The Swift half of the DOM-traversal single-source rule; the Kotlin half is
/// `WebViewDomScriptTest` in reticle-core.
///
/// The script used to be hand-copied between the two agents under a `KEEP IN SYNC`
/// comment, with different escaping on each side — so the copies could not even be
/// compared with a diff, and nothing failed when one moved. Both embeddings are now
/// asserted against `reticle-protocol/scripts/dom-traversal.js`.
final class WebViewDomScriptTests: XCTestCase {

    private func sharedScript() throws -> String {
        // <repo>/reticle-swift/Tests/ReticleProtocolTests/<this file>
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = repoRoot.appendingPathComponent("reticle-protocol/scripts/dom-traversal.js")
        return try String(contentsOf: file, encoding: .utf8)
    }

    func testTheEmbeddedScriptMatchesTheSharedFile() throws {
        let expected = try sharedScript()
        XCTAssertEqual(
            trimmingTrailingNewlines(expected),
            trimmingTrailingNewlines(WebViewDomScript.script),
            "the embedded DOM traversal script drifted from reticle-protocol/scripts/dom-traversal.js"
        )
    }

    /// A cheap guard on the property the bridge's whole design rests on: the script
    /// reads the DOM and must not mutate page state. Not a parser — it catches the
    /// obvious, which is the shape a careless edit takes.
    func testTheScriptIsStillTheReadOnlyTraversalItClaimsToBe() {
        for mutator in [".click(", ".focus(", "document.write", ".innerHTML =", ".value ="] {
            XCTAssertFalse(
                WebViewDomScript.script.contains(mutator),
                "the traversal script must not mutate the page, found '\(mutator)'"
            )
        }
    }

    private func trimmingTrailingNewlines(_ s: String) -> String {
        var out = s
        while out.hasSuffix("\n") { out.removeLast() }
        return out
    }
}
