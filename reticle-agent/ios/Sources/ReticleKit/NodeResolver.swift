import Foundation
import ReticleProtocol
#if canImport(UIKit)
import UIKit

/// Selector -> live object, inside the app process. Shared by the two in-process
/// action paths (`ActivationEngine`, `TextInputEngine`) so they cannot drift into
/// resolving the same selector differently.
///
/// Only `testId` / `ref` / `point` are matched here. `--label`, `--region` and the
/// semantic-first precedence live in the SHARED `SelectorResolution` on the host,
/// which resolves them against the same snapshot and sends a `ref` — one resolver
/// for both platforms rather than a second, weaker one in here.
@MainActor
enum NodeResolver {
    /// A SwiftUI axElement node resolves to the accessibility element itself.
    static func axElement(
        _ selector: ReticleProtocol.Selector, snapshot: Snapshot, axIndex: [String: NSObject]
    ) -> (String, NSObject)? {
        if let testId = selector.testId {
            for (ref, node) in snapshot.nodes where node.testId == testId && node.kind == .axElement {
                if let element = axIndex[ref] { return (ref, element) }
            }
        }
        if let ref = selector.ref, let element = axIndex[ref] { return (ref, element) }
        return nil
    }

    static func view(
        _ selector: ReticleProtocol.Selector, snapshot: Snapshot, index: [String: UIView]
    ) -> (String, UIView)? {
        if let testId = selector.testId {
            for (ref, node) in snapshot.nodes where node.testId == testId {
                if let v = index[ref] { return (ref, v) }
            }
        }
        if let ref = selector.ref, let v = index[ref] { return (ref, v) }
        if let point = selector.point {
            // Numeric ref order, not lexicographic — see RefOrder.
            let cg = CGPoint(x: point.x, y: point.y)
            for (ref, view) in RefOrder.descending(index) {
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
