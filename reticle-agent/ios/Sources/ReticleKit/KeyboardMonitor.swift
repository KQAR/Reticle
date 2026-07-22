import Foundation
import ReticleProtocol
#if canImport(UIKit)
import UIKit

/// Tracks the system keyboard from inside the app process — the iOS analogue of
/// the Android `KeyboardProbe`/`KeyboardController` pair.
///
/// The keyboard lives in its own system-owned windows (`UIRemoteKeyboardWindow`
/// / `UITextEffectsWindow`); the effects window attaches on first text focus and
/// never detaches, so window *presence* says nothing about visibility. The one
/// exact public signal is the keyboard notification stream, so the monitor
/// caches the latest `keyboardWillShow`/`WillHide`/`WillChangeFrame` state.
/// Before any notification has arrived (e.g. the agent was injected while the
/// keyboard was already up) it falls back to scanning for a text-input first
/// responder — visibility without a frame, reported honestly as such.
@MainActor
final class KeyboardMonitor {
    static let shared = KeyboardMonitor()

    private var observedState: KeyboardInfo?

    private init() {}

    /// Idempotent: called from the runtime once the server starts.
    func install() {
        let center = NotificationCenter.default
        center.removeObserver(self)
        center.addObserver(self, selector: #selector(keyboardChanged(_:)),
                           name: UIResponder.keyboardWillShowNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardChanged(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardHidden(_:)),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardChanged(_ note: Notification) {
        guard let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else {
            return
        }
        // A frame moved fully offscreen is a hide dressed as a change.
        let screenHeight = UIScreen.optionalMainScreen?.bounds.height ?? .greatestFiniteMagnitude
        if end.minY >= screenHeight || end.height <= 0 {
            observedState = KeyboardInfo(visible: false)
            return
        }
        observedState = KeyboardInfo(
            visible: true,
            frame: Rect(x: Double(end.minX), y: Double(end.minY),
                        width: Double(end.width), height: Double(end.height))
        )
    }

    @objc private func keyboardHidden(_ note: Notification) {
        observedState = KeyboardInfo(visible: false)
    }

    /// Current keyboard state. Notification-observed state when available;
    /// otherwise infer visibility from a text-input first responder (no frame).
    func status() -> KeyboardInfo {
        if let observedState { return observedState }
        return KeyboardInfo(visible: textInputFirstResponder() != nil)
    }

    /// Ask the focused responder to resign (the standard way an app dismisses
    /// the keyboard) and return the state as it was *before* the request.
    /// `sendAction(resignFirstResponder, to: nil)` routes to the current first
    /// responder whichever window holds it. The caller (Router, off-main) waits
    /// out the hide animation and re-reads `status()` for the settled state.
    func requestHide() -> KeyboardInfo {
        let before = status()
        if before.visible {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
        }
        return before
    }

    private func textInputFirstResponder() -> UIView? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if let responder = firstResponder(in: window), responder is UIKeyInput {
                    return responder
                }
            }
        }
        return nil
    }

    private func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = firstResponder(in: subview) { return found }
        }
        return nil
    }
}

extension UIScreen {
    /// UIScreen.main is deprecated on newer SDKs; prefer a scene screen.
    static var optionalMainScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first
    }
}
#endif
