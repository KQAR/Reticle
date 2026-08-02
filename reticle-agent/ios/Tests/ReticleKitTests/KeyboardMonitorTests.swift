import XCTest
@testable import ReticleKit

/// The pre-notification fallback: before any keyboard notification has arrived
/// (agent injected into an app that never focused a field), `status()` infers
/// visibility from the first responder. That lookup used to walk every view in
/// every window on every capture; it now asks UIKit's responder chain directly,
/// so pin that it still answers the same question.
@MainActor
final class KeyboardMonitorTests: XCTestCase {

    private var window: UIWindow!

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        window.resignKey()
        window.isHidden = true
        window = nil
    }

    func testNoFocusedFieldReadsAsNoKeyboard() {
        XCTAssertFalse(KeyboardMonitor.shared.status().visible)
    }

    func testAFocusedTextFieldReadsAsAKeyboardWithoutAFrame() throws {
        // Responder-chain dispatch needs a scene, and a headless xctest process
        // has none — the same reason the old tree walk (which enumerated
        // `connectedScenes`) found nothing here either. Left in so it runs
        // wherever a host app is available.
        try XCTSkipIf(UIApplication.shared.connectedScenes.isEmpty,
                      "no UIWindowScene in this test process")
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        window.rootViewController?.view.addSubview(field)
        guard field.becomeFirstResponder() else {
            throw XCTSkip("this process would not give the field first responder")
        }
        defer { field.resignFirstResponder() }

        let status = KeyboardMonitor.shared.status()
        XCTAssertTrue(status.visible)
        // Honest: inferred visibility carries no frame, only the notification
        // stream does.
        XCTAssertNil(status.frame)
    }

    func testANonTextResponderIsNotAKeyboard() throws {
        // A focused control that takes no keyboard input (UIKeyInput) must not
        // read as a visible keyboard — the walk this replaced checked the same.
        let view = FocusableView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        window.rootViewController?.view.addSubview(view)
        guard view.becomeFirstResponder() else {
            throw XCTSkip("this process would not give the view first responder")
        }
        defer { view.resignFirstResponder() }

        XCTAssertFalse(KeyboardMonitor.shared.status().visible)
    }
}

private final class FocusableView: UIView {
    override var canBecomeFirstResponder: Bool { true }
}
