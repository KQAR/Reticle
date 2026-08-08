import Foundation
import Testing
@testable import ReticleProtocol

/// The middle state exists because of one measurement (iPhone 13 Pro Max / iOS 26):
/// `UITextView.accessibilityActivate()` opens the `.link` run it contains and
/// answers `false` anyway. Merging that `false` into "refused" made the host throw
/// about a screen that had already navigated, so these pin the three states and the
/// fallback an older agent gets.
@Suite("Activation outcome")
struct ActivationOutcomeTests {

    @Test func theThreeStatesRoundTripOnTheWire() throws {
        for outcome in [ActivationOutcome.activated, .unconfirmed, .refused] {
            let sent = ActivationResult(activated: outcome == .activated, ref: "r14",
                                        typeName: "UITextView", via: "accessibilityActivate",
                                        message: "m", outcome: outcome)
            let back = try ReticleJSON.decode(ActivationResult.self, from: try ReticleJSON.encodeWire(sent))
            #expect(back.outcome == outcome)
            #expect(back.resolvedOutcome == outcome)
        }
    }

    @Test func anAgentThatPredatesTheFieldStillReadsAsItsOldTwoStateMeaning() throws {
        // `activated` alone is what the old agents said, and it said exactly two
        // things. Reading a missing `outcome` as anything but that would invent a
        // middle state for agents that never reported one.
        let activated = try ReticleJSON.decode(
            ActivationResult.self, from: Data(#"{"activated":true,"ref":"r1"}"#.utf8))
        #expect(activated.outcome == nil)
        #expect(activated.resolvedOutcome == .activated)

        let failed = try ReticleJSON.decode(
            ActivationResult.self, from: Data(#"{"activated":false,"ref":"r1"}"#.utf8))
        #expect(failed.outcome == nil)
        #expect(failed.resolvedOutcome == .refused)
    }

    @Test func unconfirmedIsNotActivated() {
        // The flag stays false: `unconfirmed` means nobody knows, and a caller that
        // only reads `activated` must not be told the activation landed.
        let r = ActivationResult(activated: false, outcome: .unconfirmed)
        #expect(!r.activated)
        #expect(r.resolvedOutcome == .unconfirmed)
    }
}
