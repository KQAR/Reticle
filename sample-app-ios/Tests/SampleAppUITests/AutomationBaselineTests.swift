import XCTest
import Network

/// A known-good baseline for the device's UI-automation stack.
///
/// **Run this FIRST whenever the system channel misbehaves.** It answers one
/// question and answers it in a minute: is the code broken, or is the device
/// broken? Everything it does is the shape the system channel needs — start a
/// UI-test session, keep the test alive, serve a request over the USB tunnel —
/// with none of Reticle's own machinery involved.
///
/// It exists because of a real, expensive incident. The device's automation
/// service wedged, and every launch path failed with the same
/// `Connection peer refused channel request for
/// "dtxproxy:XCTestDriverInterface:XCTestManager_IDEInterface"` →
/// `Exiting due to IDE disconnection` — which is ALSO exactly what a device with
/// "Enable UI Automation" turned off looks like, and gives no hint that the device
/// is at fault. Three rounds of device iterations went into "disproving" two
/// technical conclusions that were never actually disproven, because the
/// environment was being treated as a constant. This test would have ended that in
/// one run. A device reboot was the fix.
///
/// Usage:
///
///     iproxy -u <udid> 9500 9500 &
///     xcodebuild -project sample-app-ios/xcode/SampleAppIOS.xcodeproj \
///       -scheme SampleAppUITests -destination "platform=iOS,id=<udid>" \
///       CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM=<team> \
///       -only-testing:SampleAppUITests/AutomationBaselineTests test &
///     curl http://127.0.0.1:9500/     # expect PROBE-ALIVE
///
/// - `PROBE-ALIVE` → the device is fine; the fault is in whatever you changed.
/// - `channel refused` / `IDE disconnection` → the DEVICE is the problem. Check
///   Settings > Developer > Enable UI Automation, and if it is already on, reboot
///   the device: nothing short of that clears a wedged automation service.
final class AutomationBaselineTests: XCTestCase {

    /// Fixed, and deliberately not the system runner's port, so a stale runner can
    /// never be mistaken for this probe answering.
    static let probePort: UInt16 = 9500

    func testAutomationStackIsHealthy() throws {
        // Launch an app the same way the real paths do: a baseline that skipped
        // this would not exercise the session setup that actually breaks.
        let app = XCUIApplication()
        app.launchEnvironment["RETICLE_SAMPLE_SCENARIO"] = "login"
        app.launch()
        XCTAssertTrue(app.buttons["login.submitButton"].waitForExistence(timeout: 15),
                      "the app did not come up, so this run says nothing about the automation stack")

        NSLog("[baseline] app is up; starting listener on \(Self.probePort)")

        let listener = try NWListener(
            using: {
                let p = NWParameters.tcp
                p.allowLocalEndpointReuse = true
                return p
            }(),
            on: NWEndpoint.Port(rawValue: Self.probePort)!
        )

        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            let body = "PROBE-ALIVE"
            let head = """
            HTTP/1.1 200 OK\r
            Content-Type: text/plain\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r

            """
            connection.send(
                content: Data((head + body).utf8),
                completion: .contentProcessed { _ in connection.cancel() }
            )
        }
        listener.start(queue: .global())
        NSLog("[baseline] listener started; the automation stack is healthy")

        // Stay resident, exactly as the system channel's runner does, so this also
        // proves a never-ending test method survives on this device. Bounded so a
        // forgotten run does not hold the device's single automation session
        // forever.
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
        }

        listener.cancel()
        NSLog("[baseline] deadline reached, leaving")
    }
}
