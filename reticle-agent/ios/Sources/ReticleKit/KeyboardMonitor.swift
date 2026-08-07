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

    /// The current first responder, if it takes keyboard input.
    ///
    /// Asks UIKit instead of walking the view tree: `sendAction(to: nil)`
    /// delivers to the first responder directly, so this is O(1) where the walk
    /// was O(views) — and it ran on *every* capture until the first keyboard
    /// notification arrived, which for an app that never focuses a text field
    /// is every capture, forever. It also sees responders the walk missed (a
    /// view controller, or any non-view responder in the chain).
    ///
    /// Boundary: the dispatch goes to the key window's scene, so a first
    /// responder in some *other* foreground scene (a multi-scene iPad app) is
    /// not seen. It also finds nothing in a process with no connected scene,
    /// which is why the unit tests skip that case rather than assert it — but
    /// so did the walk, which enumerated the same (empty) scene list.
    private func textInputFirstResponder() -> UIResponder? {
        guard let responder = FirstResponderLookup.current(), responder is UIKeyInput else { return nil }
        return responder
    }
}

/// The current first responder, whichever window holds it — shared by the
/// keyboard probe and by in-process typing (which types into the focused field
/// when the caller named no target, exactly as the HID path does).
@MainActor
enum FirstResponderLookup {
    static func current() -> UIResponder? {
        let probe = FirstResponderProbe()
        UIApplication.shared.sendAction(
            #selector(UIResponder.reticleReportFirstResponder(_:)), to: nil, from: probe, for: nil)
        return probe.responder
    }
}

/// Carries the answer back out of the responder-chain dispatch above.
private final class FirstResponderProbe {
    var responder: UIResponder?
}

private extension UIResponder {
    /// Prefixed because this is injected into a host app that may define
    /// selectors of its own; the name has to stay unique in the ObjC runtime.
    @objc func reticleReportFirstResponder(_ sender: Any?) {
        (sender as? FirstResponderProbe)?.responder = self
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
