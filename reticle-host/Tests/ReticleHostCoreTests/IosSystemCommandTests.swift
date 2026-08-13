import Testing
@testable import ReticleHostCore
@testable import ReticleHostIos
import ReticleHostShared

/// TC-028 and the guidance the `system` family owes its callers.
@Suite("system command family")
struct IosSystemCommandTests {

    // TC-028. A simulator is not a degraded device here — it is the wrong tool.
    // The gap this channel fills does not exist there, so the refusal must point at
    // the commands that DO work rather than report a missing capability.
    @Test func simulatorsAreRefusedWithAPointerToTheWorkingCommands() async {
        // A simulator udid resolves through Simctl; a device udid does not. Using a
        // known-simulator id keeps this off the device.
        let simulators = await (try? Simctl.listDevices()) ?? []
        guard let sim = simulators.first else {
            // No simulators on this machine: the branch is still covered by the
            // e2e script, and inventing a fake id here would test nothing.
            return
        }
        do {
            _ = await try IosSystemBackend.make(udid: sim.udid, appBundleId: "dev.reticle.sampleios")
            Issue.record("expected a simulator to be refused")
        } catch let e as HelperError {
            #expect(e.message.contains("REAL-DEVICE"))
            // Naming the alternatives is the point of the refusal.
            #expect(e.message.contains("act tap"))
            #expect(e.message.contains("ui screenshot"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func theCommandFamilyIsIosOnlyAndSaysSo() async {
        // Default target is android; the system channel has no Android twin.
        let args = Args(["system", "status"])
        await #expect(throws: HelperError.self) { try await ReticleSystemCommands.dispatch(args) }
    }

    @Test func anUnknownSubcommandListsWhatIsAvailable() async {
        let args = Args(["system", "frobnicate", "--target", "ios"])
        do {
            await try ReticleSystemCommands.dispatch(args)
            Issue.record("expected a usage error")
        } catch let e as HelperError {
            #expect(e.message.contains("prepare"))
            #expect(e.message.contains("status"))
            #expect(e.message.contains("stop"))
            // Echo what they typed, so a typo is obvious.
            #expect(e.message.contains("frobnicate"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // Each state implies a DIFFERENT repair, which is the reason the channel has
    // three states instead of a usable/not-usable flag.
    @Test func statusAdviceDiffersPerStateAndIsAbsentWhenNothingIsNeeded() async {
        func status(_ state: SystemChannelState) -> IosSystemBackend.Status {
            IosSystemBackend.Status(
                state: state, udid: "00008110-x", port: 9346,
                runnerBundleId: IosRunnerConfig.defaultBundleId, usableTeams: ["UFSFCXQ5HZ"]
            )
        }
        // notInstalled -> prepare; installed -> just start it; connected -> nothing.
        #expect(status(.notInstalled).advice?.contains("system prepare") == true)
        #expect(status(.notInstalled).advice?.contains("UFSFCXQ5HZ") == true)
        #expect(status(.installed).advice?.contains("not connected") == true)
        #expect(status(.installed).advice?.contains("system prepare") != true)
        #expect(status(.connected).advice == nil)
    }

    @Test func statusLineCarriesTheAddressingFactsWorthSeeing() async {
        let s = IosSystemBackend.Status(
            state: .connected, udid: "00008110-x", port: 9346,
            runnerBundleId: IosRunnerConfig.defaultBundleId, usableTeams: []
        )
        #expect(s.describe.contains("connected"))
        #expect(s.describe.contains("9346"))
        #expect(s.describe.contains(IosRunnerConfig.defaultBundleId))
    }
}
