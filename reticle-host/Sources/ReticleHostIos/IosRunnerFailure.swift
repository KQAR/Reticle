import Foundation
import ReticleHostShared

/// Why the system-channel runner failed to come up, in terms a caller can act on.
///
/// This type exists because the underlying tooling LIES about the most common
/// cause. Measured on an iPhone 13 Pro Max / iOS 26 with the device-side
/// "Enable UI Automation" switch off, the runner failed as:
///
///     exit code 74 before establishing connection
///     Connection peer refused channel request for
///       "dtxproxy:XCTestDriverInterface:XCTestManager_IDEInterface"
///     Exiting due to IDE disconnection.
///
/// Not one of those lines mentions the switch. Only after a clean uninstall +
/// reinstall did the honest message appear: `Timed out while enabling automation
/// mode.` A caller handed the first form has no path to the fix — which is why
/// raw tool output must never be the error a caller sees (NFR-006).
public enum IosRunnerStartFailure: Equatable, Sendable {

    /// The device said so outright.
    case automationModeTimedOut

    /// The disguised form of the same thing: the runner started, talked to
    /// `testmanagerd`, then was refused the driver channel and exited before it
    /// ever served a request.
    ///
    /// Kept distinct from `automationModeTimedOut` on purpose. It IS the same
    /// cause in every measurement so far, but the evidence is circumstantial, and
    /// collapsing the two would state more certainty than was observed. The advice
    /// leads with the switch either way.
    case earlyExitBeforeConnection

    /// The device is locked or asleep. iOS refuses to launch there, and a runner
    /// cannot take the foreground it needs.
    case deviceLocked

    /// The runner is not installed on this device at all.
    case runnerNotInstalled

    /// No usable signing material for the requested team on this machine.
    case signingUnavailable

    /// Started and installed fine, but never answered on its port within the
    /// deadline.
    case healthTimedOut

    /// Nothing recognizable. Carries a trimmed excerpt so the report is still
    /// diagnosable rather than a shrug.
    case unrecognized(excerpt: String)

    /// Short machine-ish name for evidence lines.
    public var describe: String {
        switch self {
        case .automationModeTimedOut: return "ui-automation-disabled"
        case .earlyExitBeforeConnection: return "early-exit-before-connection"
        case .deviceLocked: return "device-locked"
        case .runnerNotInstalled: return "runner-not-installed"
        case .signingUnavailable: return "signing-unavailable"
        case .healthTimedOut: return "health-timed-out"
        case .unrecognized: return "unrecognized"
        }
    }

    /// Whether this failure points at the device-side automation switch. Used by
    /// the message builder; also the thing TC-031 pins.
    public var pointsAtAutomationSwitch: Bool {
        switch self {
        case .automationModeTimedOut, .earlyExitBeforeConnection: return true
        default: return false
        }
    }

    /// A message that names the cause and the action, with no tool output in it.
    public var advice: String {
        switch self {
        case .automationModeTimedOut:
            return """
            the device refused to enter UI automation mode. Turn ON \
            Settings > Developer > Enable UI Automation on the device (it is a \
            device-side switch and cannot be set from here), then retry
            """
        case .earlyExitBeforeConnection:
            return """
            the runner exited before it could serve anything. In every case \
            measured so far this means Settings > Developer > Enable UI Automation \
            is OFF on the device — turn it on and retry. If it is already on, the \
            runner build no longer matches this Xcode and needs `system prepare` again
            """
        case .deviceLocked:
            return """
            the device is locked or asleep. Unlock it (and set Auto-Lock to Never \
            for a long session), then retry
            """
        case .runnerNotInstalled:
            return "the system channel is not installed on this device yet. Run `system prepare --team <id>` first"
        case .signingUnavailable:
            return "no usable signing material for that team on this machine. Run `system status` to list the teams that ARE usable here"
        case .healthTimedOut:
            return """
            the runner launched but never answered on its port. Check that the USB \
            tunnel is up and that no other process holds that port, then retry
            """
        case .unrecognized(let excerpt):
            return "the runner failed for an unrecognized reason: \(excerpt)"
        }
    }

    /// The user-facing error. Never contains raw tool output — that is the whole
    /// point of this type.
    public var asError: HelperError {
        HelperError("system channel unavailable (\(describe)): \(advice)")
    }
}

/// Turns whatever the tooling emitted into an `IosRunnerStartFailure`.
///
/// Order matters: the explicit signals are checked before the circumstantial ones,
/// so a run that DID produce the honest message is never downgraded to the
/// disguised classification.
public enum IosRunnerFailureClassifier {

    /// Signals, in the order they must be tested.
    ///
    /// - `launchOutput`: what the launch/install tooling printed.
    /// - `deviceLog`: device-side log excerpt, when one was captured.
    /// - `exitCode`: the runner's exit code, when one was observed.
    /// - `installed`: whether the runner is installed at all.
    public static func classify(
        launchOutput: String = "",
        deviceLog: String = "",
        exitCode: Int32? = nil,
        installed: Bool = true
    ) -> IosRunnerStartFailure {
        let haystack = (launchOutput + "\n" + deviceLog).lowercased()

        // 1. Not installed beats every other reading: nothing else is meaningful.
        if !installed || haystack.contains("osstatus error -10814")
            || haystack.contains("application not found") {
            return .runnerNotInstalled
        }

        // 2. Signing. Checked early because it fails the build/install long before
        //    anything device-side gets a chance to complain.
        if haystack.contains("no profiles for") || haystack.contains("no accounts")
            || haystack.contains("no account for team")
            || haystack.contains("code signing") {
            return .signingUnavailable
        }

        // 3. Locked device. Distinctive wording, and NOT the automation switch —
        //    conflating the two sends the caller to the wrong screen.
        if haystack.contains("could not be, unlocked") || haystack.contains("device is locked")
            || haystack.contains("passcode") {
            return .deviceLocked
        }

        // 4. The honest automation-mode message, if we were lucky enough to get it.
        if haystack.contains("enabling automation mode")
            || haystack.contains("failed to initialize for ui testing") {
            return .automationModeTimedOut
        }

        // 5. The disguised form. Any ONE of these three is enough — they were
        //    observed together, but a caller should not need all three to get
        //    pointed at the right switch.
        if haystack.contains("xctestmanager_ideinterface")
            || haystack.contains("exiting due to ide disconnection")
            || exitCode == 74 {
            return .earlyExitBeforeConnection
        }

        // 6. Launched, installed, signed, unlocked — and simply silent.
        if haystack.isEmpty || haystack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .healthTimedOut
        }

        return .unrecognized(excerpt: excerpt(from: launchOutput.isEmpty ? deviceLog : launchOutput))
    }

    /// First non-empty line, clipped. Enough to diagnose, short enough to read.
    static func excerpt(from text: String, limit: Int = 200) -> String {
        let line = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "no output"
        return line.count > limit ? String(line.prefix(limit)) + "…" : line
    }
}
