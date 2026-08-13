import Testing
@testable import ReticleHostIos
import ReticleHostShared

/// `--alias` on iOS: refused by name, never dropped.
///
/// The `@N` aliases come from `ui outline`, whose cache lives in the Kotlin helper.
/// The Swift host serves iOS with no helper, so it has no cache to resolve one
/// against. `HostSelector.protocolSelector` narrows the alias away — which, before
/// this refusal, meant the flag simply vanished and the command ran with NO selector.
/// That is the same failure the CLI already paid for once with `act tap --text`: a
/// flag accepted and ignored reads as a flag that worked.
@Suite("iOS refuses --alias by name")
struct IosAliasRefusalTests {

    private func message(_ body: () throws -> Void) -> String? {
        do {
            try body()
            return nil
        } catch {
            return "\(error)"
        }
    }

    @Test func anAliasIsRefusedWithTheReasonAndAWayForward() {
        let text = message { try IosHelperClient.rejectAlias("@3", command: "act tap") }
        guard let text else {
            Issue.record("an alias must be refused, not accepted")
            return
        }
        // The three things a caller needs: which flag, why it cannot work here, and
        // what to use instead. A refusal missing the last one just relocates the guess.
        #expect(text.contains("--alias"))
        #expect(text.contains("act tap"), "the refusal names the command that was run")
        #expect(text.contains("ui outline"), "…and where aliases actually come from")
        #expect(text.contains("--test-id"), "…and the selectors that do work")
        #expect(text.contains("ui compact"), "…and where to get one")
    }

    @Test func noAliasIsNotAnError() {
        #expect(message { try IosHelperClient.rejectAlias(nil, command: "ui compact") } == nil)
    }

    // The narrowing that hid the flag is still the narrowing — it drops `alias`
    // because the protocol has no such concept. The guard above is what makes that
    // safe, so pin the drop too: if `protocolSelector` ever started carrying an
    // alias, the refusal would be the thing standing between a caller and a
    // selector the agent cannot resolve.
    @Test func theProtocolSelectorStillCarriesNoAlias() {
        let selector = HostSelector(testId: "checkout.payButton", alias: "@3")
        #expect(selector.alias == "@3")
        #expect(selector.protocolSelector.testId == "checkout.payButton")
    }
}
