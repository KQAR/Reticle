import Foundation
import XCTest
import ReticleProtocol

/// Cross-process input: the half of the system channel an in-process agent has no
/// equivalent for.
///
/// The authority comes from the runner's backboardd HID connection, granted
/// because this is a UI test. A digitizer `IOHIDEvent` built inside the app under
/// test is accepted and routed nowhere — measured across every sender-id and
/// coordinate-space combination — which is why this lives here and not there.
enum RunnerInput {

    static let springboardId = RunnerObservation.springboardId

    // MARK: - Tap

    /// Tap a labelled control on the topmost system modal.
    ///
    /// A missing target is refused WITH the list of what is actually there. A bare
    /// "not found" would leave the caller unable to tell a typo from a screen that
    /// moved on.
    static func tapLabel(_ label: String) -> SystemActionResult {
        let springboard = XCUIApplication(bundleIdentifier: springboardId)
        let alert = springboard.alerts.firstMatch
        let scope: XCUIElement = alert.exists ? alert : springboard

        let button = scope.buttons[label]
        guard button.exists else {
            return SystemActionResult(
                dispatched: false,
                targetProcess: springboardId,
                via: "label:\(label)",
                refusal: "no control with that label is on the system layer right now",
                available: availableLabels(in: scope)
            )
        }

        let before = signature(of: scope)
        button.tap()
        let after = signature(of: scope)
        return SystemActionResult(
            dispatched: true,
            // Compared, not assumed. "Dispatched" alone would let a no-op read as
            // success.
            changed: before != after,
            targetProcess: springboardId,
            via: "label:\(label)"
        )
    }

    /// Tap an absolute screen coordinate on the system layer.
    static func tapPoint(x: Double, y: Double) -> SystemActionResult {
        let screen = XCUIScreen.main.screenshot().image.size
        guard x >= 0, y >= 0, x <= screen.width, y <= screen.height else {
            return SystemActionResult(
                dispatched: false,
                targetProcess: springboardId,
                via: "point:\(Int(x)),\(Int(y))",
                refusal: "coordinate is outside the \(Int(screen.width))x\(Int(screen.height)) screen"
            )
        }

        let springboard = XCUIApplication(bundleIdentifier: springboardId)
        let before = signature(of: springboard)
        // Normalized against the app's own frame, which for SpringBoard is the
        // whole screen.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: x / screen.width,
                                                              dy: y / screen.height))
            .tap()
        let after = signature(of: springboard)
        return SystemActionResult(
            dispatched: true,
            changed: before != after,
            targetProcess: springboardId,
            via: "point:\(Int(x)),\(Int(y))"
        )
    }

    // MARK: - Foreground control

    static func home() -> SystemActionResult {
        XCUIDevice.shared.press(.home)
        return SystemActionResult(
            dispatched: true,
            // The caller verifies the side effect (the app leaving the foreground);
            // claiming it here would be a verdict rather than evidence.
            changed: nil,
            targetProcess: springboardId,
            via: "home"
        )
    }

    /// Bring an app back to the foreground **without restarting it**.
    ///
    /// `activate()`, never `launch()`. `launch()` relaunches the target, wiping
    /// whatever state the flow under test had built up — which would break
    /// Reticle's root promise of observing a RUNNING app. This is the single
    /// easiest line in the project to "fix" wrongly, because `launch()` is the
    /// idiomatic XCUITest call.
    static func activate(bundleId: String) -> SystemActionResult {
        let app = XCUIApplication(bundleIdentifier: bundleId)
        let wasRunning = app.state != .notRunning
        app.activate()
        return SystemActionResult(
            dispatched: true,
            changed: app.state == .runningForeground,
            targetProcess: bundleId,
            via: wasRunning ? "activate" : "activate:was-not-running"
        )
    }

    // MARK: - Helpers

    /// A cheap fingerprint of what is on a scope, used only to answer "did anything
    /// change?". Deliberately coarse: an exact tree diff would cost another
    /// full traversal, and the question here is binary.
    private static func signature(of element: XCUIElement) -> String {
        let alerts = element.alerts.count
        let buttons = element.buttons.count
        let texts = element.staticTexts.count
        return "\(alerts)/\(buttons)/\(texts)"
    }

    private static func availableLabels(in scope: XCUIElement) -> [String] {
        let buttons = scope.buttons
        var labels: [String] = []
        for i in 0..<min(buttons.count, 20) {
            let label = buttons.element(boundBy: i).label
            if !label.isEmpty { labels.append(label) }
        }
        return labels
    }
}
