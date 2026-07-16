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
/// `accessibilityActivate()` (covers many SwiftUI / custom controls). If none
/// applies the result is `activated=false` with `unsupported_activation_target`
/// — Reticle never pretends an inert view was tapped.
@MainActor
struct ActivationEngine {
    func activate(_ request: ActivationRequest) -> ActivationResult {
        let (snapshot, index, axIndex) = SnapshotCapture().captureWithIndexes()

        // axElement nodes (SwiftUI content) resolve to the accessibility
        // element itself — its activate IS the tap.
        if let (ref, element) = resolveAxElement(request.selector, snapshot: snapshot, axIndex: axIndex) {
            let typeName = snapshot.nodes[ref]?.typeName ?? NSStringFromClass(type(of: element))
            if element.accessibilityActivate() {
                return ActivationResult(activated: true, ref: ref, typeName: typeName, via: "accessibilityActivate")
            }
            return ActivationResult(
                activated: false, ref: ref, typeName: typeName,
                message: "unsupported_activation_target: accessibility element rejected activation"
            )
        }

        guard let (ref, view) = resolve(request.selector, snapshot: snapshot, index: index) else {
            return ActivationResult(activated: false, message: "no view matched selector \(request.selector.describe())")
        }
        let typeName = NSStringFromClass(type(of: view))

        // A region selector narrows the activation to a sub-target inside the
        // resolved view. Only an a11yVirtual region carries its own activatable
        // element; text-range regions (span/textMarker/colorSpan) have no
        // in-process activation surface — say so instead of tapping the whole
        // view and pretending precision.
        if let regionQuery = request.selector.region, !regionQuery.isEmpty {
            return activateRegion(regionQuery, ref: ref, view: view, snapshot: snapshot, typeName: typeName)
        }

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

    private func activateRegion(_ query: String, ref: String, view: UIView, snapshot: Snapshot, typeName: String) -> ActivationResult {
        guard let node = snapshot.nodes[ref] else {
            return ActivationResult(activated: false, ref: ref, typeName: typeName, message: "node vanished during activation")
        }
        guard let region = node.regions.first(where: { ($0.label ?? "").contains(query) }) else {
            return ActivationResult(
                activated: false, ref: ref, typeName: typeName,
                message: "no region labeled like '\(query)' on this node (\(node.regions.count) region(s) discovered)"
            )
        }
        if region.source == .a11yVirtual, let elements = view.accessibilityElements {
            for case let element as NSObject in elements where !(element is UIView) {
                let label = element.accessibilityLabel ?? ""
                if label == region.label || label.contains(query) {
                    if element.accessibilityActivate() {
                        return ActivationResult(activated: true, ref: ref, typeName: typeName, via: "accessibilityActivate(region)")
                    }
                }
            }
        }
        return ActivationResult(
            activated: false, ref: ref, typeName: typeName,
            message: "region '\(query)' (source=\(region.source.rawValue)) has no in-process activation surface; "
                + "on a simulator use `act tap --region` (HID at the region's rect)"
        )
    }

    private func resolveAxElement(_ selector: ReticleProtocol.Selector, snapshot: Snapshot, axIndex: [String: NSObject]) -> (String, NSObject)? {
        if let testId = selector.testId {
            for (ref, node) in snapshot.nodes where node.testId == testId && node.kind == .axElement {
                if let element = axIndex[ref] { return (ref, element) }
            }
        }
        if let ref = selector.ref, let element = axIndex[ref] { return (ref, element) }
        return nil
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
