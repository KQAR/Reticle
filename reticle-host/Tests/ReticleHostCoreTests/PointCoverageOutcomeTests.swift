import Foundation
import Testing
@testable import ReticleHostCore

/// The host half of the coordinate-tap coverage verdict: it is a sub-object with
/// its own printer, so it must not also be flattened into the `key=value` result
/// line, and it must not be dropped from the JSON envelope.
///
/// Both failures are quiet. A dict rendered into the fields line reads as
/// `coverage=[AnyHashable("reason"): ...]` — unreadable, and it hides the sentence
/// that is the whole product. A verdict missing from `--json` puts the silent
/// `--point` fallback straight back for every agent driving the tool that way.
@Suite("Point coverage on an act outcome")
struct PointCoverageOutcomeTests {

    private var outcome: ActOutcome {
        ActOutcome(raw: [
            "gesture": "tap",
            "x": 653,
            "y": 1540,
            "source": "point",
            "coverage": [
                "x": 653,
                "y": 1540,
                "covered": false,
                "reason": "iframe:cross-origin",
                "detail": "the frame at r18 is cross-origin",
                "warning": "no semantic selector covers (653,1540) — iframe:cross-origin: the frame at r18 is cross-origin",
                "ref": "r18",
            ] as [String: Any],
        ])
    }

    @Test func theVerdictIsReadableAsAWarningSentence() async {
        #expect(outcome.coverage?["reason"] as? String == "iframe:cross-origin")
        #expect((outcome.coverage?["warning"] as? String)?.hasPrefix("no semantic selector covers") == true)
    }

    @Test func theVerdictStaysOutOfTheFlatFieldsLine() async {
        let fields = outcome.displayFields
        #expect(fields["coverage"] == nil)
        // …and the gesture's own facts are untouched by the exclusion.
        #expect(fields["gesture"] as? String == "tap")
        #expect(fields["source"] as? String == "point")
    }

    @Test func theVerdictSurvivesIntoTheJsonEnvelope() async throws {
        let data = try JsonEnvelope.encodeSuccess(outcome.raw)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let payload = object?["data"] as? [String: Any]
        let coverage = payload?["coverage"] as? [String: Any]
        #expect(coverage?["reason"] as? String == "iframe:cross-origin")
    }

    @Test func aSelectorTapCarriesNoVerdictAtAll() async {
        // Only a coordinate needs justifying; a selector tap already resolved
        // through the tree, so a verdict there would be noise on every action.
        let selectorTap = ActOutcome(raw: ["gesture": "tap", "source": "semantic:testId", "ref": "r42"])
        #expect(selectorTap.coverage == nil)
    }

    // MARK: - Android: the host judges the helper's `tapProbe`

    /// A button with a test id, and the IME up over the bottom half.
    private static var probeTree: [String: Any] { try! JSONSerialization.jsonObject(with: Data("""
    {"schemaVersion":1,"capturedAtMillis":0,"platform":"android","rootRef":"r0",
     "screen":{"size":{"width":100,"height":200},"density":3,
               "keyboard":{"visible":true,"frame":{"x":0,"y":100,"width":100,"height":100}}},
     "nodes":{
      "r0":{"ref":"r0","kind":"application","typeName":"App","children":["b1"]},
      "b1":{"ref":"b1","parentRef":"r0","kind":"view","typeName":"android.widget.Button","role":"button",
            "testId":"pay","isInteractive":true,"frame":{"x":0,"y":0,"width":100,"height":80}}}}
    """.utf8)) as! [String: Any] }

    @Test func aCoordinateIsJudgedFromTheProbeAndTheProbeIsDropped() throws {
        let out = try AndroidBackend.judgeTap([
            "gesture": "tap", "x": 50, "y": 40, "source": "point",
            "tapProbe": ["x": 50.0, "y": 40.0, "point": true, "snapshot": Self.probeTree] as [String: Any],
        ])
        #expect(out["tapProbe"] == nil)
        let coverage = out["coverage"] as? [String: Any]
        #expect(coverage?["selector"] as? String == "--test-id pay")
        #expect((coverage?["warning"] as? String)?.hasPrefix("--point was not needed at (50,40)") == true)
        #expect(out["obstruction"] == nil)
    }

    @Test func aSelectorTapGetsAnObstructionButNoCoverage() throws {
        let out = try AndroidBackend.judgeTap([
            "gesture": "tap", "x": 50, "y": 150, "source": "semantic:testId", "ref": "b1",
            "tapProbe": ["x": 50.0, "y": 150.0, "point": false, "snapshot": Self.probeTree] as [String: Any],
        ])
        #expect(out["coverage"] == nil)
        let obstruction = out["obstruction"] as? [String: Any]
        #expect(obstruction?["reason"] as? String == "occluded:keyboard")
    }

    @Test func anUnreadableTreeIsReportedForACoordinateAndQuietForASelector() throws {
        let probe: [String: Any] = ["x": 5.0, "y": 6.0, "point": true, "error": "the tree could not be read"]
        let point = try AndroidBackend.judgeTap(["gesture": "tap", "tapProbe": probe])
        #expect((point["coverage"] as? [String: Any])?["reason"] as? String == "coverage:unavailable")
        var selectorProbe = probe
        selectorProbe["point"] = false
        let selector = try AndroidBackend.judgeTap(["gesture": "tap", "tapProbe": selectorProbe])
        #expect(selector["coverage"] == nil && selector["obstruction"] == nil && selector["tapProbe"] == nil)
    }
}
