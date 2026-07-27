import Foundation
import Testing
@testable import ReticleHostCore

/// `reticle trace log` — the read-back surface for recorded evidence.
///
/// What these pin is mostly about honesty under compression: the digest exists
/// to be short, and every shortening is a chance to imply something that was not
/// recorded. An action that changed nothing must not render the same as one
/// whose changes were merely cut for space, and a manifest that was already
/// capped at capture time must say so rather than pass its remainder off as the
/// whole picture.
@Suite("Trace digest")
struct TraceDigestTests {

    private func writeTrace(
        in root: URL,
        name: String,
        gesture: String = "tap",
        recordedAtMillis: Int64 = 1_782_875_008_204,
        selector: [String: Any]? = ["testId": "checkout.payButton"],
        params: [String: Any]? = nil,
        diff: [[String: Any]] = [],
        artifacts: [String: Any] = [
            "beforeSnapshot": "before.snapshot.json", "afterSnapshot": "after.snapshot.json",
        ]
    ) throws {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var manifest: [String: Any] = [
            "traceVersion": 1,
            "platform": "android",
            "actionId": name,
            "packageName": "dev.reticle.sample",
            "recordedAtMillis": recordedAtMillis,
            "gesture": gesture,
            "result": ["gesture": gesture],
            "artifacts": artifacts,
            "diff": diff,
        ]
        if let selector { manifest["selector"] = selector }
        if let params { manifest["params"] = params }
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: dir.appendingPathComponent("trace.json"))
    }

    private func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reticle-trace-digest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func namesTheNodeThatAppearedInsteadOfABareRef() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTrace(in: root, name: "1-tap", diff: [
            [
                "ref": "r102", "field": "present", "before": "false", "after": "true",
                "node": ["testId": "checkout.receipt", "role": "alert"],
            ],
        ])

        let text = TraceDigest.render(try TraceDigest.entries(at: root), root: root, maxChanges: 6)

        #expect(text.contains("+ r102 [testId=checkout.receipt role=alert]"))
        // The mark carries "appeared"; repeating the field would be noise.
        #expect(!text.contains("present"))
    }

    @Test func distinguishesNothingHappenedFromNothingShown() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTrace(in: root, name: "1-tap", recordedAtMillis: 1_782_875_000_000, diff: [])
        try writeTrace(
            in: root, name: "2-tap", recordedAtMillis: 1_782_875_001_000,
            diff: (0..<9).map { ["ref": "r\($0)", "field": "frame", "before": "0,0 1x1", "after": "0,\($0) 1x1"] }
        )

        let text = TraceDigest.render(try TraceDigest.entries(at: root), root: root, maxChanges: 3)

        // An action that dispatched cleanly and moved nothing is a real finding,
        // and the single most likely thing a reader is looking for.
        #expect(text.contains("(no observable change between before and after)"))
        // The other action's hidden changes are counted by field, not vanished.
        #expect(text.contains("…6 more (frame 6)"))
    }

    @Test func surfacesThatTheManifestItselfWasAlreadyCapped() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTrace(in: root, name: "1-tap", diff: [
            ["ref": "r1", "field": "text", "before": "one", "after": "two"],
            [
                "field": "truncated", "before": "242", "after": "100",
                "note": "dropped by field: frame 96, children 31",
            ],
        ])

        let text = TraceDigest.render(try TraceDigest.entries(at: root), root: root, maxChanges: 6)

        // Two different losses — capture-time and render-time — and conflating
        // them would let a reader think they had seen everything recorded.
        #expect(text.contains("! manifest kept 100 of 242 changes"))
        #expect(text.contains("frame 96, children 31"))
        // The bookkeeping marker is not itself a change.
        #expect(!text.contains("~ truncated"))
    }

    @Test func recordsWhatWasTyped() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTrace(
            in: root, name: "1-type", gesture: "type",
            selector: ["testId": "login.codeField"],
            params: ["text": "123456", "submit": "true"],
            diff: []
        )

        let text = TraceDigest.render(try TraceDigest.entries(at: root), root: root, maxChanges: 6)

        #expect(text.contains("type  testId=login.codeField  text=\"123456\"  submit"))
    }

    @Test func aScreenLevelChangeRendersWithoutARefPlaceholder() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeTrace(in: root, name: "1-tap", diff: [
            ["field": "nodeCount", "before": "102", "after": "103"],
        ])

        let text = TraceDigest.render(try TraceDigest.entries(at: root), root: root, maxChanges: 6)

        // `-` is the disappeared mark; using it as a null-ref placeholder would
        // read as "a node called nodeCount went away".
        #expect(text.contains("~ nodeCount 102 → 103"))
        #expect(!text.contains("~ - nodeCount"))
    }

    @Test func readingAnEmptyDirectoryIsAnErrorThatSaysHowToRecord() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: (any Error).self) {
            _ = try TraceDigest.entries(at: root)
        }
    }
}
