import Testing
@testable import ReticleHostIos

/// TC-031. The runner's most common failure lies about its cause, so this suite
/// pins both halves of the contract: the disguised form must be recognized, and
/// unrelated failures must NOT be swept into the same bucket.
@Suite("system runner start-failure classification")
struct IosRunnerFailureTests {

    // The honest message, when iOS bothers to emit it.
    @Test func explicitAutomationModeMessageIsRecognized() async {
        let f = IosRunnerFailureClassifier.classify(
            launchOutput: "Failed to initialize for UI testing: Error Domain=com.apple.dt.XCTest.XCTFuture Code=1000 \"Timed out while enabling automation mode.\""
        )
        #expect(f == .automationModeTimedOut)
        #expect(f.pointsAtAutomationSwitch)
        #expect(f.advice.contains("Enable UI Automation"))
    }

    // The disguised form, exactly as measured on iPhone 13 Pro Max / iOS 26 with
    // the device-side switch off. None of these lines mentions the switch, which
    // is precisely why the classifier has to.
    @Test func disguisedEarlyExitIsRecognizedAndStillPointsAtTheSwitch() async {
        let f = IosRunnerFailureClassifier.classify(
            launchOutput: "SampleAppUITests-Runner (18579) encountered an error (Early unexpected exit, operation never finished bootstrapping - no restart will be attempted. (Underlying Error: The test runner exited with code 74 before establishing connection.))",
            deviceLog: "Connection peer refused channel request for \"dtxproxy:XCTestDriverInterface:XCTestManager_IDEInterface\"; channel canceled\nExiting due to IDE disconnection."
        )
        #expect(f == .earlyExitBeforeConnection)
        #expect(f.pointsAtAutomationSwitch)
        #expect(f.advice.contains("Enable UI Automation"))
    }

    // A caller should not need all three signals to be pointed at the right screen.
    @Test func anySingleDisguiseSignalIsEnough() async {
        #expect(IosRunnerFailureClassifier.classify(exitCode: 74) == .earlyExitBeforeConnection)
        #expect(IosRunnerFailureClassifier.classify(
            deviceLog: "Exiting due to IDE disconnection."
        ) == .earlyExitBeforeConnection)
        #expect(IosRunnerFailureClassifier.classify(
            deviceLog: "channel request for dtxproxy:XCTestDriverInterface:XCTestManager_IDEInterface refused"
        ) == .earlyExitBeforeConnection)
    }

    // The other half of TC-031: unrelated failures must not be misread as the
    // automation switch, or the advice sends the caller to the wrong place.
    @Test func lockedDeviceIsNotMisreadAsTheAutomationSwitch() async {
        let f = IosRunnerFailureClassifier.classify(
            launchOutput: "The device was not, or could not be, unlocked."
        )
        #expect(f == .deviceLocked)
        #expect(!f.pointsAtAutomationSwitch)
        #expect(f.advice.lowercased().contains("unlock"))
    }

    @Test func signingFailureIsNotMisreadAsTheAutomationSwitch() async {
        let f = IosRunnerFailureClassifier.classify(
            launchOutput: "error: No profiles for 'dev.reticle.runner' were found: Xcode couldn't find any iOS App Development provisioning profiles."
        )
        #expect(f == .signingUnavailable)
        #expect(!f.pointsAtAutomationSwitch)
    }

    @Test func missingAccountIsAlsoASigningFailure() async {
        // Measured on this machine: Xcode had no account signed in at all.
        let f = IosRunnerFailureClassifier.classify(
            launchOutput: "error: No Accounts: Add a new account in Accounts settings."
        )
        #expect(f == .signingUnavailable)
    }

    @Test func notInstalledIsRecognizedFromEitherTheFlagOrTheLaunchError() async {
        #expect(IosRunnerFailureClassifier.classify(installed: false) == .runnerNotInstalled)
        // The real launch error for a missing bundle, measured via devicectl.
        let f = IosRunnerFailureClassifier.classify(
            launchOutput: "The operation couldn’t be completed. (OSStatus error -10814.)"
        )
        #expect(f == .runnerNotInstalled)
        #expect(f.advice.contains("system prepare"))
    }

    @Test func notInstalledOutranksEveryOtherReading() async {
        // With nothing installed, an automation-mode line is noise from a previous
        // run; the actionable answer is still "prepare first".
        let f = IosRunnerFailureClassifier.classify(
            launchOutput: "Timed out while enabling automation mode.",
            installed: false
        )
        #expect(f == .runnerNotInstalled)
    }

    @Test func silenceBecomesAHealthTimeoutRatherThanAnUnrecognizedFailure() async {
        #expect(IosRunnerFailureClassifier.classify() == .healthTimedOut)
        #expect(IosRunnerFailureClassifier.classify(launchOutput: "   \n  ") == .healthTimedOut)
    }

    @Test func unrecognizedFailureStillCarriesADiagnosableExcerpt() async {
        let f = IosRunnerFailureClassifier.classify(
            launchOutput: "\n\nsomething nobody has seen before happened\nsecond line"
        )
        #expect(f == .unrecognized(excerpt: "something nobody has seen before happened"))
        // A shrug is not acceptable: the excerpt has to reach the message.
        #expect(f.advice.contains("something nobody has seen before happened"))
    }

    @Test func longExcerptsAreClipped() async {
        let long = String(repeating: "x", count: 500)
        let f = IosRunnerFailureClassifier.classify(launchOutput: long)
        guard case .unrecognized(let excerpt) = f else {
            Issue.record("expected unrecognized, got \(f)")
            return
        }
        #expect(excerpt.count < 500)
        #expect(excerpt.hasSuffix("…"))
    }

    // NFR-006: raw tool output must not reach the caller's error.
    @Test func theUserFacingErrorCarriesNoRawToolOutput() async {
        let f = IosRunnerFailureClassifier.classify(
            launchOutput: "exit code 74",
            deviceLog: "Connection peer refused channel request for \"dtxproxy:XCTestDriverInterface:XCTestManager_IDEInterface\""
        )
        let message = f.asError.message
        #expect(!message.contains("dtxproxy"))
        #expect(!message.contains("74"))
        #expect(message.contains("Enable UI Automation"))
    }
}
