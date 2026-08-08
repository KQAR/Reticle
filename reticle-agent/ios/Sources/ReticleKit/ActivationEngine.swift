import Foundation
import ReticleProtocol
#if canImport(UIKit)
import UIKit

/// In-process control activation — the on-device "tap". The host cannot
/// synthesize real HID input to a physical device, but the linked agent runs
/// *inside* the app, so it can fire a control's action directly. This is the
/// iOS analogue of a programmatic tap and works on both device and simulator.
///
/// Coverage (in order): a `UIControl` gets `sendActions(for:)`; an axElement
/// node (SwiftUI content) or an a11yVirtual region gets the element's own
/// `accessibilityActivate()`; any other resolved view gets its
/// `accessibilityActivate()` (covers many SwiftUI / custom controls).
///
/// The answer is THREE-state (`ActivationOutcome`), because `accessibilityActivate()`
/// returning `false` is two different facts. Measured on an iPhone 13 Pro Max /
/// iOS 26: a `UITextView` holding a `.link` run OPENS that link — the delegate's
/// `shouldInteractWith` runs, the app navigates — and answers `false` anyway. So a
/// `false` here is reported as `unconfirmed`, not as "nothing happened", and the
/// host keeps `--verify` / `--trace-output` running for it so the caller can see
/// which it was. Only a target with no activation surface at all (a text-range
/// region, an unmatched selector) is `refused`.
///
/// What this can NEVER reach, measured on the same device: a view that handles
/// raw touches — a `UIGestureRecognizer` or `touchesBegan/Ended` doing its own
/// hit-testing. That is the real boundary, and it is about who handles the touch
/// rather than about text: the sample's self-drawn agreement rows and its
/// a11yVirtual segmented controls are all unreachable in-process, because their
/// virtual elements implement touch handling instead of `accessibilityActivate()`.
@MainActor
struct ActivationEngine {
    func activate(_ request: ActivationRequest) -> ActivationResult {
        let (snapshot, index, axIndex) = SnapshotCapture().captureWithIndexes()

        // axElement nodes (SwiftUI content) resolve to the accessibility
        // element itself — its activate IS the tap.
        if let (ref, element) = resolveAxElement(request.selector, snapshot: snapshot, axIndex: axIndex) {
            let typeName = snapshot.nodes[ref]?.typeName ?? NSStringFromClass(type(of: element))
            if element.accessibilityActivate() {
                return ActivationResult(activated: true, ref: ref, typeName: typeName,
                                        via: "accessibilityActivate", outcome: .activated)
            }
            return Self.unconfirmed(ref: ref, typeName: typeName, target: "accessibility element")
        }

        guard let (ref, view) = resolve(request.selector, snapshot: snapshot, index: index) else {
            return ActivationResult(activated: false,
                                    message: "no view matched selector \(request.selector.describe())",
                                    outcome: .refused)
        }
        let typeName = NSStringFromClass(type(of: view))

        // A region selector narrows the activation to a sub-target inside the
        // resolved view. Only an a11yVirtual region carries an element that CAN
        // be asked at all; text-range regions (span/textMarker/colorSpan) have no
        // in-process activation surface — say so instead of tapping the whole
        // view and pretending precision. And "can be asked" is not "works": a
        // virtual element only activates if the app implements
        // `accessibilityActivate()` on it, which a self-drawn control that does
        // its own hit-testing typically does not (measured on both AX conventions
        // in the sample's canvas scenario — neither activates on a device).
        if let regionQuery = request.selector.region, !regionQuery.isEmpty {
            return activateRegion(regionQuery, ref: ref, view: view, snapshot: snapshot, typeName: typeName)
        }

        if let control = view as? UIControl, control.isEnabled {
            if control.allControlEvents.contains(.primaryActionTriggered) {
                control.sendActions(for: .primaryActionTriggered)
            } else {
                control.sendActions(for: .touchUpInside)
            }
            return ActivationResult(activated: true, ref: ref, typeName: typeName,
                                    via: "sendActions", outcome: .activated)
        }

        if view.accessibilityActivate() {
            return ActivationResult(activated: true, ref: ref, typeName: typeName,
                                    via: "accessibilityActivate", outcome: .activated)
        }

        return Self.unconfirmed(ref: ref, typeName: typeName, target: typeName)
    }

    /// The middle state: `accessibilityActivate()` was called and answered `false`,
    /// which UIKit also does for activations it performed. One message for both
    /// call sites so the wording cannot drift between them.
    static func unconfirmed(ref: String, typeName: String, target: String) -> ActivationResult {
        ActivationResult(
            activated: false, ref: ref, typeName: typeName, via: "accessibilityActivate",
            message: "unconfirmed_activation: \(target) answered false to accessibilityActivate(), which "
                + "UIKit ALSO does for activations it performed (measured: a UITextView opens its .link run "
                + "and still answers false). Check the app state — `--verify <selector>` or `--trace-output` "
                + "resolves it — before concluding nothing happened. A view that handles raw touches "
                + "(UIGestureRecognizer / touchesBegan) genuinely cannot be driven in-process.",
            outcome: .unconfirmed
        )
    }

    private func activateRegion(_ query: String, ref: String, view: UIView, snapshot: Snapshot, typeName: String) -> ActivationResult {
        guard let node = snapshot.nodes[ref] else {
            return ActivationResult(activated: false, ref: ref, typeName: typeName,
                                    message: "node vanished during activation", outcome: .refused)
        }
        guard let region = node.regions.first(where: { ($0.label ?? "").contains(query) }) else {
            return ActivationResult(
                activated: false, ref: ref, typeName: typeName,
                message: "no region labeled like '\(query)' on this node (\(node.regions.count) region(s) discovered)",
                outcome: .refused
            )
        }
        if region.source == .a11yVirtual {
            // BOTH accessibility-container conventions, the same two `RegionProbe`
            // reads. Asking only the `accessibilityElements` array (what this did)
            // meant a region discovered through the container METHODS was reported
            // and then refused for a reason that was Reticle's, not the app's.
            for case let element as NSObject in RegionProbe.containerElements(view) where !(element is UIView) {
                let label = element.accessibilityLabel ?? ""
                guard label == region.label || label.contains(query) else { continue }
                if element.accessibilityActivate() {
                    return ActivationResult(activated: true, ref: ref, typeName: typeName,
                                            via: "accessibilityActivate(region)", outcome: .activated)
                }
                return Self.unconfirmed(ref: ref, typeName: typeName,
                                        target: "a11yVirtual region '\(query)'")
            }
        }
        return ActivationResult(
            activated: false, ref: ref, typeName: typeName,
            message: "region '\(query)' (source=\(region.source.rawValue)) has no in-process activation surface; "
                + "on a simulator use `act tap --region` (HID at the region's rect)",
            outcome: .refused
        )
    }

    private func resolveAxElement(_ selector: ReticleProtocol.Selector, snapshot: Snapshot, axIndex: [String: NSObject]) -> (String, NSObject)? {
        NodeResolver.axElement(selector, snapshot: snapshot, axIndex: axIndex)
    }

    private func resolve(_ selector: ReticleProtocol.Selector, snapshot: Snapshot, index: [String: UIView]) -> (String, UIView)? {
        NodeResolver.view(selector, snapshot: snapshot, index: index)
    }
}
#endif
