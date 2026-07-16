import Foundation
import ReticleProtocol
#if canImport(UIKit)
import UIKit

/// In-process control activation — the on-device "tap". The host cannot
/// synthesize real HID input to a physical device, but the linked agent runs
/// *inside* the app, so it can fire a control's action directly. This is the
/// iOS analogue of a programmatic tap and works on both device and simulator.
///
/// Coverage (in order): a `UIControl` gets `sendActions(for:)`; otherwise the
/// resolved view's `accessibilityActivate()` is tried (covers many SwiftUI /
/// custom controls that expose an activation action). If neither applies the
/// result is `activated=false` with `unsupported_activation_target` — Reticle
/// never pretends an inert view was tapped.
@MainActor
struct ActivationEngine {
    func activate(_ request: ActivationRequest) -> ActivationResult {
        let (snapshot, index) = SnapshotCapture().captureWithIndex()
        guard let (ref, view) = resolve(request.selector, snapshot: snapshot, index: index) else {
            return ActivationResult(activated: false, message: "no view matched selector \(request.selector.describe())")
        }
        let typeName = NSStringFromClass(type(of: view))

        if let control = view as? UIControl, control.isEnabled {
            if control.allControlEvents.contains(.primaryActionTriggered) {
                control.sendActions(for: .primaryActionTriggered)
            } else {
                control.sendActions(for: .touchUpInside)
            }
            return ActivationResult(activated: true, ref: ref, typeName: typeName, via: "sendActions")
        }

        if view.accessibilityActivate() {
            return ActivationResult(activated: true, ref: ref, typeName: typeName, via: "accessibilityActivate")
        }

        return ActivationResult(
            activated: false, ref: ref, typeName: typeName,
            message: "unsupported_activation_target: \(typeName) is not a UIControl and has no accessibility activation action"
        )
    }

    private func resolve(_ selector: ReticleProtocol.Selector, snapshot: Snapshot, index: [String: UIView]) -> (String, UIView)? {
        if let testId = selector.testId {
            for (ref, node) in snapshot.nodes where node.testId == testId {
                if let v = index[ref] { return (ref, v) }
            }
        }
        if let ref = selector.ref, let v = index[ref] { return (ref, v) }
        if let point = selector.point {
            let cg = CGPoint(x: point.x, y: point.y)
            for (ref, view) in index.sorted(by: { $0.key > $1.key }) {
                if let window = view.window {
                    let local = window.convert(cg, to: view)
                    if view.point(inside: local, with: nil) && (view is UIControl) { return (ref, view) }
                }
            }
        }
        return nil
    }
}
#endif
