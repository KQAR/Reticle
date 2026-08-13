import Foundation
import Testing
import ReticleProtocol
import ReticleHostShared
@testable import ReticleHostIos

/// The action-trace diff contract, driven by the language-neutral fixture at
/// reticle-protocol/fixtures/action-trace-diff.cases.json.
///
/// The Kotlin twin (`dev.reticle.core.trace.ActionTraceDiff`, exercised by
/// `ActionTraceDiffContractTest`) reads the same file. Both are hand-written 1:1
/// ports, and this diff is what a reader — often a small model with no budget to
/// open a 100KB snapshot — uses to decide whether an action landed. A rule
/// changed on one side only would let the two platforms describe the same action
/// differently; that is the failure the selector-resolution fixture exists to
/// stop happening a second time.
///
/// Order is asserted, not just membership: ranking decides what survives the
/// cap, so a diff with the right changes in the wrong order is a different
/// contract.
@Suite("Action trace diff contract")
struct ActionTraceDiffContractTests {

    private struct Case: Decodable {
        let name: String
        let why: String?
        let maxChanges: Int?
        let before: Snapshot
        let after: Snapshot
    }

    private struct Cases: Decodable {
        let cases: [Case]
        let recordedParams: [String]
    }

    private func fixtureURL() -> URL {
        // <repo>/reticle-host/Tests/ReticleHostCoreTests/<thisfile>
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ReticleHostCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // reticle-host
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("reticle-protocol/fixtures/action-trace-diff.cases.json")
    }

    /// The recorded-param allow-list exists by hand here and in Kotlin
    /// (`ActionTraceParams.RECORDED`). A key added to one side only would make
    /// the same gesture record differently on iOS and Android, and nothing in the
    /// diff cases would notice.
    @Test func recordedParamAllowListMatchesTheFixture() async throws {
        let decoded = try ReticleJSON.decode(Cases.self, from: Data(contentsOf: fixtureURL()))
        #expect(ActionTraceParamNames.recorded == decoded.recordedParams)
    }

    @Test func everyFixtureCaseDiffsAsSpecified() async throws {
        let data = try Data(contentsOf: fixtureURL())
        let decoded = try ReticleJSON.decode(Cases.self, from: data)

        // `expect` is heterogeneous (optional keys, a nested `node` object), so it
        // is read untyped and compared as JSON rather than modelled twice.
        let raw = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "fixture root must be an object"
        )
        let rawCases = try #require(raw["cases"] as? [[String: Any]], "fixture must hold a `cases` array")
        #expect(rawCases.count == decoded.cases.count)

        var failures: [String] = []
        for (index, testCase) in decoded.cases.enumerated() {
            let expected = try #require(
                rawCases[index]["expect"] as? [[String: Any]],
                "case \(testCase.name) has no `expect` list"
            )
            let actual = ActionTraceDiff.compare(
                before: testCase.before,
                after: testCase.after,
                maxChanges: testCase.maxChanges ?? 100
            )
            if NSArray(array: actual) != NSArray(array: expected) {
                failures.append(
                    """
                      - \(testCase.name)
                          why:      \(testCase.why ?? "")
                          expected: \(render(expected))
                          actual:   \(render(actual))
                    """
                )
            }
        }
        #expect(
            failures.isEmpty,
            "action-trace diff disagreed with the fixture table:\n\(failures.joined(separator: "\n"))"
        )
    }

    /// A node identified only by long text is clipped by UNICODE SCALAR (Kotlin's
    /// code point). Pinned separately from the table because the fixture's
    /// astral-plane case proves the boundary but not the unit: Swift's `prefix`
    /// counts grapheme clusters and would pass a BMP-only case while diverging
    /// from Kotlin the moment a combining sequence or emoji appears.
    @Test func identityTextIsClippedByUnicodeScalarNotGraphemeCluster() async throws {
        let emoji = "🧾" // U+1F9FE — one scalar, one grapheme, two UTF-16 units
        let body = emoji + String(repeating: "x", count: 80)
        let visible = node(ref: "r1", text: body, isVisible: true)
        let hidden = node(ref: "r1", text: body, isVisible: false)

        let changes = ActionTraceDiff.compare(before: snapshot(hidden), after: snapshot(visible))
        let identity = try #require(
            changes.first(where: { $0["ref"] as? String == "r1" })?["node"] as? [String: Any],
            "an anonymous node's text should have been carried as identity"
        )
        let clipped = try #require(identity["text"] as? String, "expected clipped identity text")

        #expect(clipped.hasSuffix("…"), "expected a trailing ellipsis: \(clipped)")
        let kept = String(clipped.dropLast())
        #expect(
            kept.unicodeScalars.count == ActionTraceDiff.identityTextLimit,
            "expected \(ActionTraceDiff.identityTextLimit) scalars before the ellipsis, got \(kept.unicodeScalars.count)"
        )
        #expect(kept.hasPrefix(emoji), "the emoji must survive whole, not split: \(clipped)")
    }

    // MARK: - helpers

    private func node(ref: String, text: String, isVisible: Bool) -> Node {
        Node(
            ref: ref,
            parentRef: "r0",
            kind: .view,
            typeName: "TextView",
            text: text,
            isVisible: isVisible
        )
    }

    private func snapshot(_ node: Node) -> Snapshot {
        Snapshot(
            capturedAtMillis: 1,
            platform: "ios",
            screen: ScreenInfo(size: Size(width: 100, height: 100), density: 1),
            rootRef: "r0",
            nodes: [
                "r0": Node(ref: "r0", kind: .application, typeName: "app", children: [node.ref]),
                node.ref: node,
            ]
        )
    }

    private func render(_ changes: [[String: Any]]) -> String {
        changes.map { change in
            let ref = change["ref"] as? String ?? "-"
            let field = change["field"] as? String ?? "?"
            let before = change["before"] as? String ?? "-"
            let after = change["after"] as? String ?? "-"
            var line = "\(ref).\(field) \(before) -> \(after)"
            if let node = change["node"] as? [String: Any] {
                let parts = node.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                line += " [\(parts.joined(separator: " "))]"
            }
            if let note = change["note"] as? String { line += " (\(note))" }
            return line
        }.joined(separator: "\n                ")
    }
}
