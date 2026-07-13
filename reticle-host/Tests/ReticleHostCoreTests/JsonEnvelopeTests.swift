import Foundation
import Testing
@testable import ReticleHostCore

@Suite("JSON envelope")
struct JsonEnvelopeTests {
    @Test func argsEnableJsonForBareFlag() {
        let args = Args(["doctor", "--json"])
        #expect(JsonEnvelope.enabled(args))
    }

    @Test func successEnvelopeUsesStableShape() throws {
        let data = try JsonEnvelope.encodeSuccess(["version": "1", "ready": true])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["ok"] as? Bool == true)
        let payload = object?["data"] as? [String: Any]
        #expect(payload?["version"] as? String == "1")
        #expect(payload?["ready"] as? Bool == true)
    }

    @Test func errorEnvelopeUsesHelperMessage() throws {
        let data = try JsonEnvelope.encodeError(HelperError("missing required --package"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["ok"] as? Bool == false)
        #expect(object?["error"] as? String == "missing required --package")
    }

    @Test func integerValuesFromHelperRepliesStayNumeric() throws {
        // Helper replies are parsed with JSONSerialization, so their values are
        // NSNumber. Integer 0/1 bridge to Bool, so a naive `as? Bool` would turn
        // counts into true/false. Verify they round-trip as numbers.
        let parsed = try JSONSerialization.jsonObject(with: Data(#"{"count":1,"zero":0,"flag":true}"#.utf8))
        let data = try JsonEnvelope.encodeSuccess(parsed)
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("\"count\":1"))
        #expect(text.contains("\"zero\":0"))
        #expect(text.contains("\"flag\":true"))
        #expect(!text.contains("\"count\":true"))
    }
}
