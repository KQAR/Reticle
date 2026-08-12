import Foundation
import XCTest
import ReticleProtocol

/// Turns XCTest's cross-process view of the screen into a `SystemObservation`.
///
/// Two things shape everything here:
///
/// 1. **Every attribute read is a cross-process query.** Measured: one traversal
///    of a WebView's tree took 126 seconds. So traversal is bounded by node count
///    AND depth, and the default target is the smallest useful one.
/// 2. **This channel sees one accessibility layer.** Whatever it cannot see is
///    named in `unreadable` rather than left empty, because an empty field reads
///    as "the app has nothing there" — the opposite of the truth.
enum RunnerObservation {

    /// Ceilings. Deliberately low: a caller who needs more asks for a narrower
    /// target, which is cheaper than waiting minutes for a tree nobody reads.
    static let nodeLimit = 200
    static let depthLimit = 30

    static let springboardId = "com.apple.springboard"

    // MARK: - Topmost overlay

    /// What is currently covering the app under test, if anything.
    ///
    /// Scope is honest about itself: this recognizes SYSTEM MODALS (permission
    /// alerts, system sheets), which is what the channel exists for. A Home screen
    /// or another app in the foreground is not reported as an "overlay" — nothing
    /// is covering the app then, the app simply is not in front. Ask for those by
    /// name with `tree(target:)`.
    static func topmostOverlay() -> SystemObservation {
        let springboard = XCUIApplication(bundleIdentifier: springboardId)
        let alert = springboard.alerts.firstMatch

        guard alert.exists else {
            // A positive answer, not an empty tree: "nothing is covering the app"
            // and "I read nothing" lead to opposite next moves.
            return SystemObservation(overlayPresent: false, targetProcess: springboardId)
        }

        var walker = Walker()
        let root = walker.walk(alert, parent: nil, depth: 0)
        return SystemObservation(
            rootRef: root,
            nodes: walker.nodes,
            overlayPresent: true,
            truncation: walker.truncation(),
            targetProcess: springboardId
        )
    }

    // MARK: - Explicit targets

    static func tree(target: SystemReadTarget) -> SystemObservation {
        switch target {
        case .topmostOverlay:
            return topmostOverlay()
        case .home:
            return snapshot(of: XCUIApplication(bundleIdentifier: springboardId),
                            process: springboardId)
        case .app(let bundleId):
            return snapshot(of: XCUIApplication(bundleIdentifier: bundleId), process: bundleId)
        }
    }

    private static func snapshot(of app: XCUIApplication, process: String) -> SystemObservation {
        guard app.exists else {
            return SystemObservation(overlayPresent: false, targetProcess: process)
        }
        var walker = Walker()
        let root = walker.walk(app, parent: nil, depth: 0)
        return SystemObservation(
            rootRef: root,
            nodes: walker.nodes,
            // An explicitly requested target is not a claim about what covers the
            // app; `overlayPresent` stays true only because something WAS read.
            overlayPresent: true,
            truncation: walker.truncation(),
            targetProcess: process
        )
    }

    // MARK: - Walk

    private struct Walker {
        var nodes: [String: SystemNode] = [:]
        var budget = RunnerObservation.nodeLimit
        var hitLimit = false
        var counter = 0

        mutating func truncation() -> SystemTruncation? {
            guard hitLimit else { return nil }
            return SystemTruncation(
                returned: nodes.count,
                limit: RunnerObservation.nodeLimit,
                reason: "node-limit"
            )
        }

        mutating func nextRef() -> String {
            counter += 1
            return "s\(counter)"
        }

        /// Returns the ref of the node written, or nil when the budget ran out.
        mutating func walk(_ element: XCUIElement, parent: String?, depth: Int) -> String? {
            guard budget > 0 else { hitLimit = true; return nil }
            guard depth <= RunnerObservation.depthLimit else { hitLimit = true; return nil }
            budget -= 1

            let ref = nextRef()
            // One snapshot of the attributes, then children. Reading attributes
            // twice would double the cross-process cost for nothing.
            let node = SystemNode(
                ref: ref,
                parentRef: parent,
                children: [],
                role: SystemRole.fromElementType(Int(element.elementType.rawValue)),
                label: nonEmpty(element.label),
                value: nonEmpty(element.value as? String),
                placeholder: nonEmpty(element.placeholderValue),
                testId: nonEmpty(element.identifier),
                frame: rect(element.frame),
                isEnabled: element.isEnabled,
                isHittable: element.isHittable
            )
            nodes[ref] = node

            var childRefs: [String] = []
            let children = element.children(matching: .any)
            for i in 0..<children.count {
                guard budget > 0 else { hitLimit = true; break }
                if let childRef = walk(children.element(boundBy: i), parent: ref, depth: depth + 1) {
                    childRefs.append(childRef)
                }
            }
            nodes[ref]?.children = childRefs
            return ref
        }

        private func nonEmpty(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            return s
        }

        private func rect(_ r: CGRect) -> Rect? {
            guard !r.isNull, !r.isInfinite else { return nil }
            return Rect(x: r.origin.x, y: r.origin.y, width: r.size.width, height: r.size.height)
        }
    }
}
