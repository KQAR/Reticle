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
}
