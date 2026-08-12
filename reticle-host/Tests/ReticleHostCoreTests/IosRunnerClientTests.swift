import Foundation
import Testing
@testable import ReticleHostIos
import ReticleHostShared
import ReticleProtocol

/// The client's addressing and the restart-reporting rule.
///
/// Anything that needs a live device is covered by `scripts/e2e-ios-system.sh`
/// instead; what is worth pinning here is that a restart, when it happens, ends up
/// ON the evidence rather than only in a log line.
@Suite("system runner client")
struct IosRunnerClientTests {

    private func session() -> IosRunnerSession {
        IosRunnerSession(lifecycle: IosRunnerLifecycle(
            config: IosRunnerConfig(appBundleId: "dev.reticle.sampleios"),
            udid: "00008110-000A05D03683801E"
        ))
    }

    @Test func theClientAddressesTheRunnersOwnDerivedPort() {
        let config = IosRunnerConfig(appBundleId: "dev.reticle.sampleios")
        let client = IosRunnerClient(config: config)
        #expect(client.port == config.port)
        // Not the app's port — that one belongs to the linked agent.
        #expect(client.port != config.appPort)
    }

    @Test func aSuccessfulCallReportsNoRestart() throws {
        let (value, restarted) = try session().withRetry { _ in 42 }
        #expect(value == 42)
        #expect(!restarted)
    }

    // NFR-011: when nothing was restarted, nothing may be claimed. A spurious
    // restart flag would send someone hunting for interference that never happened.
    @Test func anUninterruptedObservationIsNotStampedAsRestarted() throws {
        let observed = try session().observe { _ in
            SystemObservation(overlayPresent: true, targetProcess: "com.apple.springboard")
        }
        #expect(!observed.runnerRestarted)
        #expect(observed.sourceChannel == SystemObservation.channelName)
    }

    // A refusal the runner deliberately returned must propagate untouched: a
    // restart would paper over the runner's own considered answer.
    @Test func anErrorFromALiveRunnerIsNotRetriedIntoSilence() {
        // With no device attached the liveness probe reads "not running", so this
        // exercises the path where a retry IS attempted and then fails for real —
        // the point being that the original failure surfaces rather than a success.
        #expect(throws: (any Error).self) {
            _ = try session().withRetry { _ -> Int in
                throw HelperError("runner said no")
            }
        }
    }

    @Test func observationsDecodeFromTheRunnersWireShape() throws {
        // The shape the runner is expected to emit for a system alert, trimmed to
        // one node. Pinning it here keeps host and runner from drifting silently.
        let json = """
        {
          "rootRef": "s1",
          "nodes": {
            "s1": {
              "ref": "s1",
              "children": [],
              "role": "button",
              "label": "允许",
              "isEnabled": true,
              "isHittable": true,
              "unreadable": {"isVisible": "system-channel-has-no-visibility-signal"}
            }
          },
          "overlayPresent": true,
          "sourceChannel": "system-runner",
          "targetProcess": "com.apple.springboard",
          "runnerRestarted": false
        }
        """
        let obs = try ReticleJSON.decode(SystemObservation.self, from: json)
        #expect(obs.overlayPresent)
        #expect(obs.nodes["s1"]?.role == .button)
        #expect(obs.nodes["s1"]?.label == "允许")
        #expect(obs.nodes["s1"]?.unreadable["isVisible"] != nil)
        #expect(obs.targetProcess == "com.apple.springboard")
    }
}
