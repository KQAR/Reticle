import XCTest
import ReticleProtocol
@testable import ReticleKit

/// The view walk itself: the thing every command reads, and until now the
/// largest piece of the agent with no coverage at all.
///
/// A unit-test process has no `UIWindowScene`, so the capture takes its windows
/// as an argument (nil = the live enumeration, which is what production uses).
/// That one seam makes the whole walk testable over a hand-built hierarchy —
/// refs, parent/child links, screen-space frames, the visibility filter, and the
/// two projections derived from the same capture.
@MainActor
final class SnapshotCaptureTests: XCTestCase {

    private func makeWindow() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        return window
    }

    /// A small screen: a labelled button, a text label, and a hidden row.
    private func populate(_ window: UIWindow) {
        let button = UIButton(frame: CGRect(x: 24, y: 700, width: 342, height: 50))
        button.accessibilityIdentifier = "checkout.payButton"
        button.setTitle("Pay now", for: .normal)
        window.addSubview(button)

        let label = UILabel(frame: CGRect(x: 24, y: 100, width: 342, height: 24))
        label.accessibilityIdentifier = "checkout.total"
        label.text = "Total: $42"
        window.addSubview(label)

        let hidden = UILabel(frame: CGRect(x: 24, y: 200, width: 342, height: 24))
        hidden.accessibilityIdentifier = "checkout.debugBanner"
        hidden.text = "DEBUG BUILD"
        hidden.isHidden = true
        window.addSubview(hidden)

        window.layoutIfNeeded()
    }

    private func capture(_ windows: [UIWindow]) -> Snapshot {
        SnapshotCapture(windows: windows).captureWithIndex().0
    }

    func testTheTreeIsRootedAtAnApplicationNodeWithOneChildPerWindow() throws {
        let a = makeWindow(), b = makeWindow()
        let snapshot = capture([a, b])

        let root = try XCTUnwrap(snapshot.root())
        XCTAssertEqual(root.kind, .application)
        XCTAssertEqual(root.children.count, 2)
        for ref in root.children {
            XCTAssertEqual(snapshot.nodes[ref]?.kind, .window, "a window root must be marked as one")
        }
        XCTAssertEqual(snapshot.platform, "ios")
    }

    func testEveryNodeIsReachableFromTheRootAndPointsBackAtItsParent() throws {
        let window = makeWindow()
        populate(window)
        let snapshot = capture([window])

        var seen = Set<String>()
        func walk(_ ref: String) {
            guard let node = snapshot.nodes[ref], seen.insert(ref).inserted else { return }
            for child in node.children {
                XCTAssertEqual(snapshot.nodes[child]?.parentRef, ref, "child \(child) disagrees about its parent")
                walk(child)
            }
        }
        walk(snapshot.rootRef)
        XCTAssertEqual(seen.count, snapshot.nodes.count, "the walk left orphan nodes in the map")
    }

    func testAnAccessibilityIdentifierBecomesTheTestIdAndFindsItsNode() throws {
        let window = makeWindow()
        populate(window)
        let snapshot = capture([window])

        let pay = try XCTUnwrap(snapshot.first { $0.testId == "checkout.payButton" })
        XCTAssertEqual(pay.role, "button")
        XCTAssertTrue(pay.isInteractive, "a UIButton is the canonical tappable node")
    }

    func testFramesAreInScreenCoordinatesSoATapPointNeedsNoConversion() throws {
        let window = makeWindow()
        populate(window)
        let snapshot = capture([window])

        let frame = try XCTUnwrap(snapshot.first { $0.testId == "checkout.payButton" }?.frame)
        XCTAssertEqual(frame.x, 24, accuracy: 0.5)
        XCTAssertEqual(frame.y, 700, accuracy: 0.5)
        XCTAssertEqual(frame.width, 342, accuracy: 0.5)
    }

    func testAHiddenViewIsCapturedAndMarkedRatherThanDropped() throws {
        // The snapshot is the full record — the FILTER lives in the compact
        // projection. Dropping it here would make `ui node` unable to answer
        // "is that banner still in the tree".
        let window = makeWindow()
        populate(window)
        let snapshot = capture([window])

        let banner = try XCTUnwrap(snapshot.first { $0.testId == "checkout.debugBanner" })
        XCTAssertFalse(banner.isVisible)

        let compact = CompactObservation.from(snapshot)
        XCTAssertFalse(
            compact.items.contains { $0.testId == "checkout.debugBanner" },
            "compact is for acting now, so an invisible node must not appear in it"
        )
        XCTAssertTrue(compact.items.contains { $0.testId == "checkout.payButton" })
    }

    func testTwoCapturesOfTheSameTreeAgreeOnEveryRef() throws {
        // Refs are positional, and mutation re-resolves one by replaying the walk.
        // If the numbering moved between two identical captures, `mutate --ref`
        // would patch a different view than the one the caller read.
        let window = makeWindow()
        populate(window)

        let first = capture([window])
        let second = capture([window])
        XCTAssertEqual(
            first.nodes.mapValues { $0.testId ?? $0.typeName },
            second.nodes.mapValues { $0.testId ?? $0.typeName }
        )
    }

    func testARefResolvesBackToTheViewItWasTakenFrom() throws {
        let window = makeWindow()
        populate(window)

        let (snapshot, index) = SnapshotCapture(windows: [window]).captureWithIndex()
        let payRef = try XCTUnwrap(snapshot.first { $0.testId == "checkout.payButton" }?.ref)
        let view = try XCTUnwrap(index[payRef])
        XCTAssertEqual((view as? UIButton)?.title(for: .normal), "Pay now")
    }

    func testScreenInfoComesFromTheWindowBeingCaptured() throws {
        let window = makeWindow()
        let snapshot = capture([window])
        XCTAssertGreaterThan(snapshot.screen.size.width, 0)
        XCTAssertGreaterThan(snapshot.screen.density, 0)
        // fontScale separates "the app asked for the wrong size" from "the user
        // enlarged text", so an absent one silently breaks the sp conversion.
        XCTAssertNotNil(snapshot.screen.fontScale)
    }

    func testTheSemanticProjectionKeepsTargetableNodesAndDropsScaffolding() throws {
        let window = makeWindow()
        populate(window)
        let container = UIView(frame: CGRect(x: 0, y: 300, width: 390, height: 100))
        let nested = UILabel(frame: CGRect(x: 8, y: 8, width: 200, height: 24))
        nested.accessibilityIdentifier = "row.title"
        nested.text = "Nested"
        container.addSubview(nested)
        window.addSubview(container)
        window.layoutIfNeeded()

        let snapshot = capture([window])
        let semantic = SemanticTree.build(from: snapshot)
        XCTAssertNotNil(semantic.nodes.values.first { $0.testId == "row.title" })
        // The anonymous container carries no targeting signal of its own.
        XCTAssertNil(semantic.nodes.values.first { $0.ref == container.accessibilityIdentifier })
        // …and the derived tree stays connected: every kept node's parent is kept.
        for node in semantic.nodes.values {
            if let parent = node.parentRef {
                XCTAssertNotNil(semantic.nodes[parent], "semantic node \(node.ref) points at a dropped parent")
            }
        }
    }

    func testAnAppAuthoredProbeIsCapturedAsAChildOfTheApplication() throws {
        // The app-authored channel: metadata a host app publishes for its own
        // screens, addressable by testId like any other node. The registry is
        // process-global, so the test retracts what it published — which is the
        // reason `clearProbes()` exists at all.
        Reticle.clearProbes()
        defer { Reticle.clearProbes() }
        Reticle.registerProbe(testId: "checkout.state", metadata: ["cart": .text("3 items")])

        let snapshot = capture([makeWindow()])
        let probe = try XCTUnwrap(snapshot.first { $0.testId == "checkout.state" })
        XCTAssertEqual(probe.kind, .probe)
        XCTAssertEqual(probe.parentRef, snapshot.rootRef)
    }

    func testAnEmptyWindowListStillProducesAWellFormedSnapshot() throws {
        Reticle.clearProbes()
        // Degrade to an empty screen rather than to a broken document: a caller
        // must be able to read "nothing attached" without special-casing.
        let snapshot = capture([])
        XCTAssertEqual(snapshot.root()?.kind, .application)
        XCTAssertTrue(snapshot.root()?.children.isEmpty ?? false)
        XCTAssertTrue(CompactObservation.from(snapshot).items.isEmpty)
    }
}
