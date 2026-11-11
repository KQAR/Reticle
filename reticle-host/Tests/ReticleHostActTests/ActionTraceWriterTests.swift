import Foundation
import Testing
import ReticleProtocol
@testable import ReticleHostAct

/// The writer's file layout: snapshots verbatim, each screenshot moved from where
/// `capture` wrote it into the action's directory, and a manifest naming both.
struct ActionTraceWriterTests {
    private func snapshot(text: String) -> Snapshot {
        Snapshot(
            capturedAtMillis: 0, platform: "ios",
            screen: ScreenInfo(size: Size(width: 390, height: 844), density: 3),
            rootRef: "r0",
            nodes: ["r0": Node(ref: "r0", kind: .view, typeName: "UILabel", text: text)]
        )
    }

    @Test func writesBothSidesAndMovesTheScreenshotsIn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trace-writer-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let texts = ["before", "after"]
        var calls = 0
        let writer = ActionTraceWriter(root: root, packageName: "dev.example", recordedParams: [:]) { url in
            let text = texts[min(calls, 1)]
            calls += 1
            let snap = snapshot(text: text)
            try? Data(text.utf8).write(to: url)
            return TraceCapture(snapshotJSON: try! ReticleJSON.encodeWire(snap), snapshot: snap, screenshot: url)
        }
        let before = try #require(await writer.record())
        let out = try await writer.write(
            gesture: "tap", selector: nil, targetPoint: nil, targetSource: nil, targetRef: nil,
            result: [:], before: before, settleMs: 0
        )

        let dir = URL(fileURLWithPath: try #require(out["path"] as? String))
        #expect(try String(contentsOf: dir.appendingPathComponent("before.screenshot.png"), encoding: .utf8) == "before")
        #expect(try String(contentsOf: dir.appendingPathComponent("after.screenshot.png"), encoding: .utf8) == "after")
        #expect(!FileManager.default.fileExists(atPath: before.screenshot!.path), "the staged file is moved, not copied")
        let manifest = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("trace.json"))) as? [String: Any]
        )
        let artifacts = try #require(manifest["artifacts"] as? [String: String])
        #expect(artifacts["beforeScreenshot"] == "before.screenshot.png")
        #expect(artifacts["afterScreenshot"] == "after.screenshot.png")
        #expect(out["changeCount"] as? Int == 1)
    }
}
