import Foundation
import ReticleHostShared
import ReticleProtocol

/// The executor behind the `system` command family.
///
/// Deliberately NOT a `HostBackend`. That protocol is shared with Android, and
/// none of these methods exists there — adding them would force the Android
/// backend to implement a capability its platform does not have, just to throw.
/// The two channels stay separate all the way up to the CLI.
public final class IosSystemBackend: Sendable {

    public let lifecycle: IosRunnerLifecycle
    public let session: IosRunnerSession

    public init(lifecycle: IosRunnerLifecycle) {
        self.lifecycle = lifecycle
        self.session = IosRunnerSession(lifecycle: lifecycle)
    }

    /// Build one for a device, refusing simulators by name.
    ///
    /// A simulator is not a degraded case here, it is the WRONG TOOL: on a
    /// simulator input already goes through the system pipeline, so a coordinate
    /// tap reaches a permission alert and `simctl io … screenshot` shows it. The
    /// whole system channel exists for the device gap. Saying so — and naming the
    /// command to use instead — is more useful than a capability error.
    public static func make(udid: String, appBundleId: String) async throws -> IosSystemBackend {
        if await Simctl.isSimulator(udid) {
            throw HelperError(
                "the system channel is a REAL-DEVICE capability and \(udid) is a simulator. "
                + "On a simulator the gap it fills does not exist: input already goes through "
                + "the system pipeline, so `act tap` reaches a system alert and `ui screenshot` "
                + "shows it. Use those instead"
            )
        }
        let config = IosRunnerConfig(appBundleId: appBundleId)
        try config.assertNoPortCollision()
        return IosSystemBackend(lifecycle: IosRunnerLifecycle(config: config, udid: udid))
    }

    // MARK: - Status

    public struct Status: Sendable {
        public var state: SystemChannelState
        public var udid: String
        public var port: Int
        public var runnerBundleId: String
        /// Teams with usable signing material here, so a failed prepare can point
        /// at what WOULD work instead of only at what did not.
        public var usableTeams: [String]

        /// One line, in the shape the rest of the CLI prints.
        public var describe: String {
            "system: \(state.rawValue) device=\(udid) port=\(port) runner=\(runnerBundleId)"
        }

        /// What to do next, when there is something to do.
        public var advice: String? {
            switch state {
            case .notInstalled:
                return "not installed yet — run `reticle system prepare --team <id>`"
                    + (usableTeams.isEmpty ? "" : " (usable teams here: \(usableTeams.joined(separator: ", ")))")
            case .installed:
                return "installed but not connected — the next `system` command will start it"
            case .connected:
                return nil
            }
        }
    }

    public func status() async -> Status {
        await Status(
            state: lifecycle.state(),
            udid: lifecycle.udid,
            port: lifecycle.config.port,
            runnerBundleId: lifecycle.config.bundleId,
            usableTeams: IosRunnerLifecycle.usableTeams().sorted()
        )
    }

    // MARK: - Prepare / stop

    public func prepare(team: String, runnerProjectPath: String) async throws -> IosRunnerLifecycle.PrepareOutcome {
        await try lifecycle.prepare(
            team: team,
            runnerProjectPath: runnerProjectPath,
            derivedDataPath: lifecycle.derivedDataPath
        )
    }

    public func stop() async -> IosRunnerLifecycle.StopOutcome {
        await lifecycle.stop()
    }

    // MARK: - Observation (Phase 2 fills these in)

    /// Read the topmost overlay. Every result is stamped with its channel and the
    /// process it is about, and every property this channel cannot read is named
    /// in `unreadable` rather than left empty — an empty field would read as "the
    /// app really has nothing there", which is the opposite of the truth.
    public func overlay() async throws -> SystemObservation {
        let started = try await lifecycle.ensureConnected().didStart
        return await stamp(try session.observe { try $0.overlay() }, started: started)
    }

    public func tree(target: SystemReadTarget) async throws -> SystemObservation {
        let started = try await lifecycle.ensureConnected().didStart
        return await stamp(try session.observe { try $0.tree(target: target) }, started: started)
    }

    /// Carry "the runner had to be started for this command" onto the evidence.
    ///
    /// `IosRunnerSession` already flags a mid-request restart, but a start that
    /// happens in `ensureConnected` — the common case after the channel was
    /// stopped, or after the runner was reclaimed — would otherwise go unreported
    /// even though it disturbed the foreground exactly the same way.
    private func stamp(_ obs: SystemObservation, started: Bool) -> SystemObservation {
        guard started, !obs.runnerRestarted else { return obs }
        var out = obs
        out.runnerRestarted = true
        return out
    }

    // MARK: - Driving

    /// Dispatch an action and carry back what actually happened.
    ///
    /// The result never claims success — it reports `dispatched` and, separately,
    /// whether anything observably `changed`. A tap that landed and moved nothing
    /// is a real outcome, and calling it "success" would be a verdict rather than
    /// evidence.
    public func act(_ body: @escaping (IosRunnerClient) async throws -> SystemActionResult) async throws -> SystemActionResult {
        let started = try await lifecycle.ensureConnected().didStart
        let (result, restartedMidRequest) = try await session.withRetry(body)
        guard started || restartedMidRequest else { return result }
        var out = result
        out.runnerRestarted = true
        return out
    }

    /// A display-level screenshot, tagged so it can never be confused with the
    /// in-process one. `degraded` carries what THIS picture cannot show, matching
    /// how `ui screenshot` already reports its own blind spots.
    public func screenshot() async throws -> ScreenshotResult {
        let started = try await lifecycle.ensureConnected().didStart
        let (png, restartedMidRequest) = try await session.withRetry { try $0.screenshotPng() }
        let restarted = started || restartedMidRequest
        var degraded: [String] = []
        if restarted {
            // The restart took the foreground away from whatever was there. Saying
            // so is the difference between evidence and a lie of omission.
            degraded.append("runner:restarted-during-capture")
        }
        return ScreenshotResult(
            pngBase64: png.base64EncodedString(),
            via: "system-runner:display",
            degraded: degraded
        )
    }
}
