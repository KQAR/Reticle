import Foundation
import ReticleProtocol
import Testing
@testable import ReticleHostCore
@testable import ReticleHostShared

/// `ui outline` and `act --alias` on Android, now that the alias cache is the
/// host's: outline writes it; a tap re-finds the entry in the live tree here, and a
/// helper-run gesture (`type`) is sent the entry as `aliasEntry`.
@Suite(.serialized)
struct OutlineAliasTests {
    private final class Recording: HelperCalling, @unchecked Sendable {
        var calls: [(method: String, params: [String: Any])] = []
        var reply: [String: Any] = [:]
        func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            calls.append((method, params))
            return reply
        }
    }

    private static let snapshotJSON = """
    {"schemaVersion":1,"capturedAtMillis":123,"platform":"android",
     "screen":{"size":{"width":1080,"height":2400},"density":3},"rootRef":"app","nodes":{
      "app":{"ref":"app","kind":"application","typeName":"Application","children":["button"]},
      "button":{"ref":"button","parentRef":"app","kind":"view","typeName":"android.widget.Button",
        "role":"button","testId":"checkout.payButton","text":"Pay",
        "frame":{"x":10,"y":200,"width":100,"height":40},"isInteractive":true}}}
    """

    private func tempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reticle-alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func outlineWritesTheCacheAndActSendsTheResolvedEntry() async throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let transport = Recording()
        transport.reply = ["snapshot": try JSONSerialization.jsonObject(with: Data(Self.snapshotJSON.utf8))]
        let backend = AndroidBackend(transport, serial: "emulator-5554", aliasHome: home)

        let text = try backend.render(RenderRequest(
            view: "outline", snapshotPath: RenderRequest.liveSnapshotPath, package: "dev.reticle.sample"
        )).text
        #expect(text.contains("@1 #checkout.payButton button \"Pay\" [10,200 100x40] tappable"))
        #expect(transport.calls.map(\.method) == ["uiReport"], "outline renders in the host")

        // A tap re-finds the entry in the live tree (it is where the cache says).
        let tap = try await backend.act(ActRequest(
            gesture: "tap", package: "dev.reticle.sample", selector: HostSelector(alias: "@1")
        ))
        #expect(tap.raw["source"] as? String == "outline:@1->live")
        #expect(tap.raw["ref"] as? String == "button")
        #expect(transport.calls.map(\.method).last == "input")

        transport.reply = ["gesture": "type"]
        var type = ActRequest(gesture: "type", package: "dev.reticle.sample", selector: HostSelector(alias: "@1"))
        type.text = "x"
        _ = try await backend.act(type)
        let sent = try #require(transport.calls.last?.params)
        #expect(sent["alias"] as? String == "@1")
        let entry = try #require(sent["aliasEntry"] as? [String: Any])
        #expect(entry["testId"] as? String == "checkout.payButton")
        #expect((entry["frame"] as? [String: Any])?["y"] as? Double == 200)
    }

    @Test func waitRefusesAnAliasByNameWithoutReadingTheCache() async throws {
        let transport = Recording()
        let backend = AndroidBackend(transport, aliasHome: try tempHome())
        await #expect(throws: HelperError.self) {
            _ = try await backend.act(ActRequest(gesture: "wait", package: "p", selector: HostSelector(alias: "@1")))
        }
        #expect(transport.calls.isEmpty)
    }

    @Test func cacheMissesAndCorruptionAreCleanErrors() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        func message(_ alias: String = "@1") -> String {
            do {
                _ = try OutlineAliasCache.resolve(alias, serial: "s", package: "p", home: home)
                return ""
            } catch { return "\(error)" }
        }
        #expect(message().contains("no outline alias cache for 'p'"))

        let file = OutlineAliasCache.cacheFile(serial: "s", package: "p", home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: file)
        #expect(message().contains("corrupt"))
        try Data(#"{"version":1,"entries":[{"alias":"@1","ref":"r","role":"button"}]}"#.utf8).write(to: file)
        #expect(message().contains("corrupt"))
        try Data(#"{"version":2,"entries":[]}"#.utf8).write(to: file)
        #expect(message().contains("version mismatch"))

        let snapshot = try ReticleJSON.decode(Snapshot.self, from: Data(Self.snapshotJSON.utf8))
        try OutlineAliasCache.write(snapshot, Outline.render(snapshot).entries, serial: "s", package: "p", home: home)
        #expect(message("@9").contains("Cached aliases: @1"))
    }

    @Test func aLongIdKeepsAReadablePrefixPlusADigest() {
        #expect(OutlineAliasCache.sanitize("emulator-5554") == "emulator-5554")
        #expect(OutlineAliasCache.sanitize("a:b/c") == "a_b_c")
        let long = OutlineAliasCache.sanitize(String(repeating: "x", count: 100))
        #expect(long.count == 72 + 1 + 12)
    }
}
