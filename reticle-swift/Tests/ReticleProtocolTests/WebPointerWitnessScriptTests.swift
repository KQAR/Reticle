import XCTest
@testable import ReticleProtocol

/// The Swift half of the pointer witness's single-source rule; the Kotlin half is
/// `WebPointerWitnessScriptTest` in reticle-core.
final class WebPointerWitnessScriptTests: XCTestCase {

    private func sharedScript() throws -> String {
        // <repo>/reticle-swift/Tests/ReticleProtocolTests/<this file>
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let file = repoRoot.appendingPathComponent("reticle-protocol/scripts/dom-pointer-witness.js")
        return try String(contentsOf: file, encoding: .utf8)
    }

    func testTheEmbeddedScriptMatchesTheSharedFile() throws {
        let expected = try sharedScript()
        XCTAssertEqual(
            trimmingTrailingNewlines(expected),
            trimmingTrailingNewlines(WebPointerWitnessScript.script),
            "the embedded pointer witness drifted from reticle-protocol/scripts/dom-pointer-witness.js"
        )
    }

    /// The size of the one write Reticle makes into a page. A witness that grew a
    /// `preventDefault` would suppress the app's own handler and become the bug.
    func testTheWitnessOnlyObserves() {
        for forbidden in [
            "preventDefault", "stopPropagation", "stopImmediatePropagation",
            ".click(", ".focus(", ".innerHTML =", ".value =", "document.write",
        ] {
            XCTAssertFalse(
                WebPointerWitnessScript.script.contains(forbidden),
                "the pointer witness must only observe, found '\(forbidden)'"
            )
        }
        XCTAssertTrue(WebPointerWitnessScript.script.contains("addEventListener"))
        XCTAssertTrue(WebPointerWitnessScript.script.contains("passive"))
    }

    private func trimmingTrailingNewlines(_ s: String) -> String {
        var out = s
        while out.hasSuffix("\n") { out.removeLast() }
        return out
    }
}
