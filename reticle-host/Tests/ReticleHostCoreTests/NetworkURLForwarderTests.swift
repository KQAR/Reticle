import Foundation
import Testing
@testable import ReticleNetworkLane

@Suite("Network URL forwarder")
struct NetworkURLForwarderTests {
    @Test func resourceTimeoutKeepsTheFloorForShortRequestTimeouts() {
        #expect(NetworkURLForwarder.resourceTimeout(forRequestTimeout: 30) == 600)
        #expect(NetworkURLForwarder.resourceTimeout(forRequestTimeout: 600) == 600)
    }

    @Test func resourceTimeoutNeverClampsAConfiguredLongerTimeout() {
        // A --upstream-timeout above the floor used to be silently cut to 600s
        // by the hardcoded session-level resource timeout.
        #expect(NetworkURLForwarder.resourceTimeout(forRequestTimeout: 1800) == 1800)
    }
}
