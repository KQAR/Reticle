import Foundation
import Testing
@testable import ReticleHostCore

@Suite("Action batch")
struct ActionBatchTests {
    @Test func parsesBatchStepArray() throws {
        let data = Data("""
        [
          { "gesture": "tap", "testId": "checkout.payButton" },
          { "gesture": "type", "text": "hello", "delayMs": 50 }
        ]
        """.utf8)

        let steps = try actionBatchSteps(from: data)

        #expect(steps.count == 2)
        #expect(steps[0]["gesture"] as? String == "tap")
        #expect(steps[0]["testId"] as? String == "checkout.payButton")
        #expect((steps[1]["delayMs"] as? NSNumber)?.intValue == 50)
    }

    @Test func rejectsNonArrayBatchFile() {
        let data = Data(#"{ "gesture": "tap" }"#.utf8)

        #expect(throws: HelperError.self) {
            _ = try actionBatchSteps(from: data)
        }
    }
}
