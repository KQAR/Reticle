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
}
