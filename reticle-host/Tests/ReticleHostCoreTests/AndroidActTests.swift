import Foundation
import ReticleProtocol
import Testing
@testable import ReticleHostCore
@testable import ReticleHostShared

/// Android `act` orchestrated in the host: the helper only captures (`snapshot`)
/// and dispatches (`input`, `hideKeyboard`, `toastWatch`), and every decision —
/// resolution, the settle confirm, the tap's evidence, verify, the trace — is
/// made here. Driven through `AndroidBackend` over a fake transport, so the RPC
/// sequence itself is asserted.
@Suite(.serialized)
struct AndroidActTests {

    /// A `pay` button at the top; a `low` button under a visible keyboard.
    static let screen = #"""
    {"schemaVersion":1,"capturedAtMillis":0,"platform":"android","rootRef":"r0",
     "screen":{"size":{"width":100,"height":200},"density":3,
               "keyboard":{"visible":true,"frame":{"x":0,"y":100,"width":100,"height":100}}},
     "nodes":{
      "r0":{"ref":"r0","kind":"application","typeName":"App","children":["b1","b2","t1"]},
      "b1":{"ref":"b1","parentRef":"r0","kind":"view","typeName":"android.widget.Button","role":"button",
            "testId":"pay","text":"Pay","isVisible":true,"isInteractive":true,"frame":{"x":0,"y":0,"width":100,"height":80}},
      "b2":{"ref":"b2","parentRef":"r0","kind":"view","typeName":"android.widget.Button","role":"button",
            "testId":"low","isVisible":true,"isInteractive":true,"frame":{"x":0,"y":120,"width":100,"height":60}},
      "t1":{"ref":"t1","parentRef":"r0","kind":"view","typeName":"android.widget.TextView",
            "testId":"caption","text":"Caption","isVisible":true,"frame":{"x":0,"y":85,"width":100,"height":10}}}}
    """#

    private func act(
        _ gesture: String, _ selector: HostSelector = .init(), transport: SnapshotTransport? = nil,
        configure: (inout ActRequest) -> Void = { _ in }
    ) async throws -> (ActOutcome, SnapshotTransport) {
        let transport = transport ?? SnapshotTransport(Self.screen)
        var request = ActRequest(gesture: gesture, package: "p", selector: selector)
        configure(&request)
        return (try await AndroidBackend(transport).act(request), transport)
    }

    @Test func aSelectorTapResolvesConfirmsAndDispatchesInTheHost() async throws {
        let (out, t) = try await act("tap", HostSelector(testId: "pay"))
        #expect(t.methods == ["toastWatch", "snapshot", "snapshot", "input", "toastWatch"])
        #expect(!t.methods.contains("act"), "a tap no longer reaches the helper's act")
        // Only the first read probes the runtime.
        #expect(t.params("snapshot").map { $0["probe"] as? Bool } == [true, false])
        let input = try #require(t.params("input").first)
        #expect(input["kind"] as? String == "tap" && input["x"] as? Int == 50 && input["y"] as? Int == 40)
        #expect(out.raw["source"] as? String == "semantic:testId")
        #expect(out.raw["ref"] as? String == "b1")
        // Printed as `settled=1`, the form callers already grep for.
        #expect("\(out.raw["settled"]!)" == "1")
        #expect(out.raw["rectMoved"] == nil && out.raw["obstruction"] == nil && out.raw["coverage"] == nil)
    }

    @Test func aSelectorTapUnderTheKeyboardReportsTheObstruction() async throws {
        let (out, _) = try await act("tap", HostSelector(testId: "low"))
        #expect(out.obstruction?["reason"] as? String == "occluded:keyboard")
    }

    @Test func aTapOnANodeWithNoControlSaysSo() async throws {
        let (out, _) = try await act("tap", HostSelector(testId: "caption"))
        #expect(out.targetInert?.contains("publishes no control of its own") == true)
    }

    @Test func aCoordinateIsJudgedAndNeverConfirmed() async throws {
        let (out, t) = try await act("tap", HostSelector(point: "50,40"))
        #expect(t.methods.filter { $0 == "snapshot" }.count == 1, "a raw point has nothing to re-resolve")
        #expect(out.coverage?["selector"] as? String == "--test-id pay")
        #expect(out.raw["settled"] == nil)
    }

    @Test func aCoordinateStillGoesOutWhenTheTreeCannotBeRead() async throws {
        let transport = SnapshotTransport(Self.screen)
        transport.failSnapshot = true
        let (out, t) = try await act("tap", HostSelector(point: "5,6"), transport: transport)
        #expect(t.methods.contains("input"))
        #expect(out.coverage?["reason"] as? String == "coverage:unavailable")
    }

    @Test func aSelectorTapNeedsTheTree() async {
        let transport = SnapshotTransport(Self.screen)
        transport.failSnapshot = true
        await #expect(throws: HelperError.self) {
            _ = try await act("tap", HostSelector(testId: "pay"), transport: transport)
        }
        #expect(!transport.methods.contains("input"))
        // The toast watch it opened is closed, not left to the helper's reaper.
        #expect(transport.methods.last == "toastWatch")
    }

    @Test func settleWithAPointIsRefusedBeforeAnyInput() async {
        let transport = SnapshotTransport(Self.screen)
        await #expect(throws: HelperError.self) {
            _ = try await act("tap", HostSelector(point: "1,2"), transport: transport) { $0.settle = true }
        }
        #expect(!transport.methods.contains("input"))
    }

    @Test func activateAndUnknownGesturesAreRefusedBeforeAnyCall() async {
        for gesture in ["activate", "pinch"] {
            let transport = SnapshotTransport(Self.screen)
            await #expect(throws: HelperError.self) { _ = try await act(gesture, transport: transport) }
            #expect(transport.calls.isEmpty)
        }
    }

    @Test func swipeAndDragAreOneInputEach() async throws {
        let (swipe, s) = try await act("swipe") { $0.from = "1,2"; $0.to = "3,4" }
        #expect(swipe.raw["durationMs"] as? Int == 300)
        let input = try #require(s.params("input").first)
        #expect(input["kind"] as? String == "swipe" && input["from"] as? String == "1,2" && input["to"] as? String == "3,4")
        let (drag, _) = try await act("drag") { $0.from = "1,2"; $0.to = "3,4" }
        #expect(drag.raw["durationMs"] as? Int == 1000)
        await #expect(throws: HelperError.self) { _ = try await act("swipe") { $0.from = "1,2" } }
    }

    @Test func hideKeyboardIsTheHelpersOneCall() async throws {
        let (out, t) = try await act("hide-keyboard") { $0.noToastProbe = true }
        #expect(t.methods == ["hideKeyboard"])
        #expect(out.raw["via"] as? String == "agent imm")
    }

    @Test func aHelperGestureIsSentWithoutTheEnvelope() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reticle-trace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (out, t) = try await act("type", HostSelector(testId: "pay")) {
            $0.text = "hi"; $0.verify = "#pay"; $0.verifyTimeoutMs = 0; $0.traceOutput = dir.path
        }
        let sent = try #require(t.params("act").first)
        #expect(sent["text"] as? String == "hi" && sent["testId"] as? String == "pay")
        for key in AndroidBackend.envelopeKeys { #expect(sent[key] == nil, "\(key) is the host's") }
        // …and the host wrapped it in that envelope itself.
        #expect(out.verify != nil)
        #expect(out.trace?["manifest"] as? String == "trace.json")
    }

    @Test func aToastSeenDuringTheActionIsOnTheResultAndInTheTrace() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reticle-trace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = SnapshotTransport(Self.screen)
        transport.toasts = [["summary": "Saved", "kind": "text", "duration": "short"], ["summary": "Again", "kind": "text"]]
        let (out, _) = try await act("tap", HostSelector(testId: "pay"), transport: transport) {
            $0.traceOutput = dir.path; $0.traceDelayMs = 0
        }
        #expect(out.raw["toast"] as? String == "Saved")
        #expect(out.raw["toastKind"] as? String == "text" && out.raw["toastDuration"] as? String == "short")
        #expect(out.raw["toastCount"] as? Int == 2)
        let manifest = try Self.manifest(out)
        #expect((manifest["result"] as? [String: Any])?["toast"] as? String == "Saved")
    }

    @Test func theTraceIsWrittenByTheHostAndTheTapReusesItsFirstCapture() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reticle-trace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (out, t) = try await act("tap", HostSelector(label: "Pay")) {
            $0.traceOutput = dir.path; $0.traceDelayMs = 0; $0.noToastProbe = true
        }
        // before (+png, probed) → settle → input → after (+png).
        #expect(t.methods == ["snapshot", "snapshot", "input", "snapshot"])
        let snapshots = t.params("snapshot")
        #expect(snapshots[0]["probe"] as? Bool == true && snapshots[0]["screenshotPath"] != nil)
        #expect(snapshots[1]["screenshotPath"] == nil)
        let manifest = try Self.manifest(out)
        #expect(manifest["traceVersion"] as? Int == 1)
        #expect(manifest["platform"] as? String == "android")
        // `--label` is recorded as the selector it is.
        #expect((manifest["selector"] as? [String: Any])?["label"] as? String == "Pay")
        #expect((manifest["target"] as? [String: Any])?["ref"] as? String == "b1")
        let result = try #require(manifest["result"] as? [String: String])
        #expect(result["settled"] == "true" && result["x"] == "50")
        let artifacts = try #require(manifest["artifacts"] as? [String: Any])
        #expect(artifacts["beforeScreenshot"] as? String == "before.screenshot.png")
    }

    @Test func aCoordinatesVerdictIsWrittenIntoTheManifestAsJson() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reticle-trace-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (out, _) = try await act("tap", HostSelector(point: "50,40")) {
            $0.traceOutput = dir.path; $0.traceDelayMs = 0
        }
        let result = try #require(try Self.manifest(out)["result"] as? [String: String])
        let coverage = try JSONSerialization.jsonObject(with: Data(try #require(result["coverage"]).utf8)) as? [String: Any]
        #expect(coverage?["selector"] as? String == "--test-id pay")
    }

    @Test func anAutomaticTraceThatCannotCaptureDropsTheTraceNotTheAction() async throws {
        let transport = SnapshotTransport(Self.screen)
        transport.failSnapshot = true
        let (out, t) = try await act("swipe", transport: transport) {
            $0.from = "1,2"; $0.to = "3,4"; $0.traceOutput = "/tmp/unused"; $0.traceAuto = true
        }
        #expect(out.trace == nil && t.methods.contains("input"))
    }

    private static func manifest(_ out: ActOutcome) throws -> [String: Any] {
        let trace = try #require(out.trace)
        let url = URL(fileURLWithPath: try #require(trace["path"] as? String)).appendingPathComponent("trace.json")
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}

/// `AliasMatch`: re-finding a cached `@N` entry in a live tree (#326 §5).
struct AliasMatchTests {
    private static func dom(_ ref: String, tag: String, id: String? = nil, nth: Int, y: Double, parent: String) -> String {
        let idField = id.map { #","domId":{"_type":"text","value":"\#($0)"}"# } ?? ""
        return #"""
        "\#(ref)":{"ref":"\#(ref)","parentRef":"\#(parent)","kind":"domNode","typeName":"\#(tag)","isVisible":true,
          "frame":{"x":0,"y":\#(y),"width":100,"height":40},
          "custom":{"domTag":{"_type":"text","value":"\#(tag)"},"domNthOfType":{"_type":"int","value":\#(nth)}\#(idField)}}
        """#
    }

    /// `body > ul > li:nth-of-type(1..3)`, the second one carrying `id=pay`.
    private static var page: Snapshot {
        let json = #"""
        {"schemaVersion":1,"capturedAtMillis":0,"platform":"android","rootRef":"body",
         "screen":{"size":{"width":100,"height":400},"density":3},"nodes":{
          \#(dom("body", tag: "body", nth: 1, y: 0, parent: "")),
          \#(dom("ul", tag: "ul", nth: 1, y: 0, parent: "body")),
          \#(dom("li1", tag: "li", nth: 1, y: 100, parent: "ul")),
          \#(dom("li2", tag: "li", id: "pay", nth: 2, y: 200, parent: "ul")),
          \#(dom("li3", tag: "li", nth: 3, y: 300, parent: "ul"))}}
        """#
        var snapshot = try! SnapshotRender.decode(Data(json.utf8))
        snapshot.nodes["body"]!.children = ["ul"]
        snapshot.nodes["ul"]!.children = ["li1", "li2", "li3"]
        snapshot.nodes["body"]!.parentRef = nil
        return snapshot
    }

    private func entry(css: String, y: Double) -> Outline.Entry {
        let json = #"{"alias":"@1","ref":"stale","role":"link","css":"\#(css)","enabled":true,"interactive":true,"#
            + #""frame":{"x":0,"y":\#(y),"width":100,"height":40}}"#
        return try! JSONDecoder().decode(Outline.Entry.self, from: Data(json.utf8))
    }

    @Test func aShortenedIdHandleMatchesTheFullPath() {
        #expect(AliasMatch.live(Self.page, entry(css: "#pay", y: 0))?.ref == "li2")
    }

    @Test func aPathSuffixHandleMatchesTheFullPath() {
        #expect(AliasMatch.live(Self.page, entry(css: "ul > li:nth-of-type(3)", y: 0))?.ref == "li3")
    }

    @Test func aHandleNoLongerUniqueTakesTheNearestToTheCachedFrame() {
        #expect(AliasMatch.live(Self.page, entry(css: "ul > li", y: 290))?.ref == "li3")
        #expect(AliasMatch.live(Self.page, entry(css: "ul > li", y: 110))?.ref == "li1")
    }

    @Test func anUnsupportedHandleIsAMissNotAnError() {
        #expect(AliasMatch.live(Self.page, entry(css: "li[data-x]", y: 200)) == nil)
    }
}
