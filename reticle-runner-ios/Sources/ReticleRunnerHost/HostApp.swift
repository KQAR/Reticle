import SwiftUI

/// A do-nothing app that exists only to be the runner's test host.
///
/// Measured on iPhone 13 Pro Max / iOS 26: a UI-test bundle with NO target
/// application never gets an automation session — the runner starts, prints
/// `Running tests...`, is refused the
/// `dtxproxy:XCTestDriverInterface:XCTestManager_IDEInterface` channel, and exits.
/// The same bundle with a host attached works. (WebDriverAgentRunner has no host
/// and does work, so this is a difference in project configuration rather than a
/// hard platform rule — but a host is the configuration that is known to work here.)
///
/// It is deliberately NOT the app under test: the system channel drives other
/// processes by bundle id (`XCUIApplication(bundleIdentifier:)`), so hosting here
/// costs nothing and keeps the runner independent of whatever is being tested.
@main
struct ReticleRunnerHostApp: App {
    var body: some Scene {
        WindowGroup {
            // Text only, no interaction: anything tappable here would be a way to
            // accidentally drive the host instead of the target.
            Text("Reticle system channel host")
                .accessibilityIdentifier("runnerHost.idle")
        }
    }
}
