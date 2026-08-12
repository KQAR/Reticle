import XCTest
import UIKit
import ReticleProtocol

/// The never-ending test that IS the system channel.
///
/// A UI-test method is the only context on iOS where XCTest's cross-process
/// observation and input are available, and the runner's whole trick is to enter
/// one and never leave: the server starts, the method blocks on a run loop, and the
/// process stays alive serving requests. WebDriverAgent's `testRunner` does exactly
/// this, comment and all ("Never ending test used to start WebDriverAgent").
///
/// Two device-side facts this rests on, both measured on an iPhone 13 Pro Max /
/// iOS 26 (see specs/ios-system-scope/explore.md):
///
/// 1. `xcrun devicectl device process launch` starts this bundle with no IDE and no
///    xcodebuild attached — the device synthesizes its own test configuration
///    (`Synthesizing a test configuration for the test bundle` → `Running tests…`).
///    That is what makes "prepare once, launch many times" possible.
/// 2. The runner is granted a backboardd HID connection
///    (`HID connection … bundleID:dev.reticle.runner.xctrunner successful`), which
///    is where its cross-process input authority comes from. An in-process agent
///    has no equivalent — a digitizer `IOHIDEvent` built inside the app under test
///    is accepted and routed nowhere.
final class RunnerServerTest: XCTestCase {

    override func setUp() {
        super.setUp()
        // A failure must not tear down the server: this method is a service, not a
        // test, and a torn-down service looks to the host like a vanished runner.
        continueAfterFailure = true
    }

    func testRunsSystemChannelForever() throws {
        let port = PortMap.derivePort(RunnerServerTest.runnerBundleId)
        let server = RunnerHTTPServer(port: port)

        registerRoutes(on: server)

        try server.start()
        NSLog("[reticle-runner] system channel listening on 127.0.0.1:\(port)")

        // Open the automation session ONCE. Every XCUIElement attribute read is a
        // cross-process query, so paying the session cost per request would compound
        // an already minutes-expensive traversal (measured: 126s for one WebView).
        _ = XCUIApplication(bundleIdentifier: "com.apple.springboard")

        // Block. Returning from here would end the test and kill the process, so
        // this loop is the runner's entire lifetime.
        while !server.shutdownRequested {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
        }

        server.stop()
        NSLog("[reticle-runner] shutdown requested, leaving")
    }

    // MARK: - Routes

    private func registerRoutes(on server: RunnerHTTPServer) {
        server.route("GET /health") { _ in
            let screen = XCUIScreen.main.screenshot().image.size
            let payload: [String: Any] = [
                "version": RunnerServerTest.runnerVersion,
                "screenWidth": screen.width,
                "screenHeight": screen.height,
                "pointScale": UIScreen.main.scale,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
                return .failure(500, "could not encode health")
            }
            return .json(data)
        }

        server.route("GET /system/overlay") { _ in
            Self.encode(RunnerObservation.topmostOverlay())
        }

        server.route("GET /system/tree") { request in
            // Default is the topmost overlay: it is the question this channel
            // exists to answer, and a full system-layer walk is minutes-expensive.
            let raw = request.query["target"] ?? "topmost"
            let target: SystemReadTarget
            switch raw {
            case "topmost": target = .topmostOverlay
            case "home": target = .home
            default: target = .app(bundleId: raw)
            }
            return Self.encode(RunnerObservation.tree(target: target))
        }

        server.route("GET /system/screenshot") { _ in
            // Display-level, so it includes whatever is covering the app — which is
            // precisely what an in-process screenshot cannot show on a device.
            .png(XCUIScreen.main.screenshot().pngRepresentation)
        }

        server.route("POST /system/tap") { request in
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            if let label = body["label"] as? String {
                return Self.encodeAction(RunnerInput.tapLabel(label))
            }
            guard let x = body["x"] as? Double, let y = body["y"] as? Double else {
                return .failure(400, "tap needs either {\"label\":…} or {\"x\":…,\"y\":…}")
            }
            return Self.encodeAction(RunnerInput.tapPoint(x: x, y: y))
        }

        server.route("POST /system/home") { _ in
            Self.encodeAction(RunnerInput.home())
        }

        server.route("POST /system/activate") { request in
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
            guard let bundleId = body["bundleId"] as? String, !bundleId.isEmpty else {
                return .failure(400, "activate needs {\"bundleId\":…}")
            }
            return Self.encodeAction(RunnerInput.activate(bundleId: bundleId))
        }

        server.route("POST /shutdown") { _ in
            // Answer BEFORE leaving, so `system stop` gets a clean confirmation
            // rather than a dropped connection it would have to interpret.
            server.requestShutdown()
            let data = (try? JSONSerialization.data(withJSONObject: ["stopped": true])) ?? Data()
            return .json(data)
        }
    }

    /// Encode with the SHARED protocol encoder, so the host decodes exactly what
    /// this wrote — the two ends use one type, not two hand-written copies.
    private static func encode(_ observation: SystemObservation) -> RunnerHTTPServer.Response {
        guard let data = try? ReticleJSON.encodeWire(observation) else {
            return .failure(500, "could not encode the observation")
        }
        return .json(data)
    }

    private static func encodeAction(_ result: SystemActionResult) -> RunnerHTTPServer.Response {
        guard let data = try? ReticleJSON.encodeWire(result) else {
            return .failure(500, "could not encode the action result")
        }
        // A refusal is a 200 with `dispatched:false`, not an HTTP error: it is a
        // considered answer about the screen, and the host needs its `available`
        // list rather than a status code.
        return .json(data)
    }

    /// The test target's own id. XCTest appends `.xctrunner` for the app that is
    /// installed, and the PORT is derived from that installed id — the host derives
    /// it from the same string, which is what makes the two ends meet without a
    /// discovery round-trip.
    static let runnerBundleId = "dev.reticle.runner.xctrunner"

    /// Named `runnerVersion`, not `version`: `NSObject` already exports a
    /// `version` selector, and a static named `version` on an XCTestCase subclass
    /// collides with it at the Objective-C level.
    static let runnerVersion = "0.1.0"
}
