import Testing
@testable import ReticleHostIos
import ReticleHostShared
import ReticleProtocol

/// TC-029 plus the addressing rules that are easy to get wrong here.
@Suite("system runner lifecycle wiring")
struct IosRunnerLifecycleTests {

    // TC-029. Two channels on one port would fight over a single USB tunnel, and
    // the symptom would look like anything but a port clash — so it is refused at
    // prepare time rather than left to chance.
    @Test func collidingPortsAreRefusedRatherThanSilentlyShared() throws {
        // Same id on both ends is the degenerate collision: identical hash input.
        let colliding = IosRunnerConfig(bundleId: "dev.reticle.same", appBundleId: "dev.reticle.same")
        #expect(colliding.port == colliding.appPort)
        #expect(throws: HelperError.self) { try colliding.assertNoPortCollision() }
    }

    @Test func theRefusalNamesBothSidesAndThePortSoItIsActionable() {
        let colliding = IosRunnerConfig(bundleId: "dev.reticle.same", appBundleId: "dev.reticle.same")
        do {
            try colliding.assertNoPortCollision()
            Issue.record("expected a collision refusal")
        } catch let e as HelperError {
            #expect(e.message.contains("dev.reticle.same"))
            #expect(e.message.contains("\(colliding.port)"))
            // The reason matters as much as the fact: a bare "port conflict" would
            // not tell anyone why it is worth refusing up front.
            #expect(e.message.contains("intermittent"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test func distinctBundleIdsNormallyLandOnDistinctPorts() throws {
        let config = IosRunnerConfig(
            bundleId: IosRunnerConfig.defaultBundleId,
            appBundleId: "dev.reticle.sampleios"
        )
        #expect(config.port != config.appPort)
        try config.assertNoPortCollision()
    }

    // The port must come from the shared rule, not from a new allocator: one place
    // where ports are decided is the invariant worth pinning.
    @Test func portsComeFromTheSharedDerivationRule() {
        let config = IosRunnerConfig(appBundleId: "dev.reticle.sampleios")
        #expect(config.port == PortMap.derivePort(IosRunnerConfig.defaultBundleId))
        #expect(config.appPort == PortMap.derivePort("dev.reticle.sampleios"))
        // And it stays inside the assigned range, so it cannot stray onto some
        // unrelated service's port.
        #expect(config.port >= PortMap.basePort)
        #expect(config.port < PortMap.basePort + PortMap.range)
    }

    @Test func theRunnerBundleIdCarriesTheXctrunnerSuffix() {
        // XCTest appends it to the test target's id; a config without it would point
        // at an app that does not exist on the device.
        #expect(IosRunnerConfig.defaultBundleId.hasSuffix(".xctrunner"))
    }

    // One device identifier, not two. Measured: the hardware UDID is accepted by
    // devicectl, iproxy and xcodebuild alike, so carrying a second id (the
    // coredevice UUID, which only devicectl accepts) would add a way to be wrong
    // without adding any reach.
    @Test func lifecycleTakesASingleDeviceIdentifier() {
        let lc = IosRunnerLifecycle(
            config: IosRunnerConfig(appBundleId: "dev.reticle.sampleios"),
            udid: "00008110-000A05D03683801E"
        )
        #expect(lc.udid == "00008110-000A05D03683801E")
        // The xctestrun that lets a later session skip building lives under the
        // derived-data path, so a default has to exist for a bare construction.
        #expect(!lc.derivedDataPath.isEmpty)
    }

    @Test func channelStatesAreThreeWayNotBoolean() {
        // notInstalled and installed need opposite repairs, so they must stay
        // distinguishable all the way out to the caller.
        #expect(SystemChannelState.notInstalled != SystemChannelState.installed)
        #expect(SystemChannelState.installed != SystemChannelState.connected)
        #expect(SystemChannelState.notInstalled.rawValue == "notInstalled")
    }

    @Test func profileValueExtractionPullsTheApplicationIdentifier() {
        // Wildcard profiles are how signing works on a machine with no Xcode
        // account signed in, so parsing them is load-bearing.
        let xml = """
        <plist><dict>
        <key>Name</key><string>iOS Team Provisioning Profile: *</string>
        <key>application-identifier</key><string>UFSFCXQ5HZ.*</string>
        </dict></plist>
        """
        #expect(IosRunnerLifecycle.value(of: "application-identifier", in: xml) == "UFSFCXQ5HZ.*")
        #expect(IosRunnerLifecycle.value(of: "Name", in: xml) == "iOS Team Provisioning Profile: *")
        #expect(IosRunnerLifecycle.value(of: "not-present", in: xml) == nil)
    }
}
