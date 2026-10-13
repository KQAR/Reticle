import Foundation
import Testing
@testable import ReticleHostIos
import ReticleProtocol

/// A simulator shares the Mac's loopback, so the same app on two simulators puts
/// two agents on one derived port and the second never binds. The agent names its
/// simulator; these pin how the host reads that.
@Suite("iOS agent identity")
struct IosAgentIdentityTests {

    @Test func theTargetSimulatorsOwnAgentPasses() {
        #expect(IosHelperClient.identityMismatch(pkg: "dev.app", port: 9000,
                                                 answeredFrom: "SIM-A", target: "SIM-A") == nil)
    }

    @Test func anotherSimulatorsAgentIsAConflictThatSaysHowToResolveIt() throws {
        let reason = try #require(IosHelperClient.identityMismatch(pkg: "dev.app", port: 9000,
                                                                  answeredFrom: "SIM-B", target: "SIM-A"))
        #expect(reason.contains("SIM-B") && reason.contains("SIM-A"))
        #expect(reason.contains("simctl terminate SIM-B dev.app"))
        #expect(reason.contains("--serial SIM-B"))
    }

    // The documented device case: a simulator's copy of the app holds the port the
    // device tunnel wanted, so a command aimed at the phone is answered from the Mac.
    @Test func aSimulatorAnsweringForADeviceTargetIsAConflict() {
        #expect(IosHelperClient.identityMismatch(pkg: "dev.app", port: 9000,
                                                 answeredFrom: "SIM-B", target: "00000000-0000000000000000") != nil)
    }

    @Test func deviceIdIsOmittedFromTheWireWhenAbsentAndDecodesFromAnOlderAgent() throws {
        let old = #"{"packageName":"dev.app","processName":"App","pid":1,"sdkInt":26,"agentVersion":"0","port":9000}"#
        let info = try ReticleJSON.decode(RuntimeInfo.self, from: Data(old.utf8))
        #expect(info.deviceId == nil)
        #expect(info.simulator == nil)
        let encoded = String(decoding: try ReticleJSON.encodeWire(info), as: UTF8.self)
        #expect(!encoded.contains("deviceId"))
        #expect(!encoded.contains("simulator"))
    }

    // The reverse case: a device cannot name itself, so the refusal has to say
    // which tunnel to stop and which flag reaches the device instead.
    @Test func aDeviceAnsweringForASimulatorTargetSaysHowToResolveIt() {
        let reason = IosHelperClient.deviceAnsweringForSimulator(pkg: "dev.app", port: 9000, target: "SIM-A")
        #expect(reason.contains("port conflict") && reason.contains("SIM-A"))
        #expect(reason.contains("iproxy") && reason.contains("9000") && reason.contains("--serial"))
    }
}
