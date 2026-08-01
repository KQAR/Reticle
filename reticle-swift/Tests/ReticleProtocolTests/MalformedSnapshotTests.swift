import XCTest
@testable import ReticleProtocol

/// Malformed snapshots must produce a bounded, deterministic answer — never a
/// hang or unbounded recursion. The Swift twin of reticle-core's
/// `MalformedSnapshotTest`; the two must stay aligned like every other
/// derivation pair in this repo.
///
/// A snapshot is not always a fresh capture: it can be loaded from disk
/// (`--snapshot file`) or produced by a buggy agent build, so a parentRef
/// cycle, a children cycle, or one ref listed under two parents are legitimate
/// inputs to every derivation. The assertion in most of these tests is simply
/// that the call RETURNS.
final class MalformedSnapshotTests: XCTestCase {

    /// A parentRef cycle among two dropped wrappers (`x` <-> `y`), below a real
    /// window. `leaf` is a kept node whose ancestor walk enters the cycle.
    private func parentCycleSnapshot() -> Snapshot {
        let nodes: [String: Node] = [
            "app": Node(ref: "app", kind: .application, typeName: "Application", children: ["w"]),
            "w": Node(ref: "w", parentRef: "app", kind: .window, typeName: "UIWindow",
                      frame: Rect(x: 0, y: 0, width: 1000, height: 2000), children: ["x"]),
            // Malformed on purpose: x's parentRef points into a cycle with y,
            // not at the window that actually lists it as a child.
            "x": Node(ref: "x", parentRef: "y", kind: .view, typeName: "UIView",
                      frame: Rect(x: 0, y: 0, width: 1000, height: 2000), children: ["leaf"]),
            "y": Node(ref: "y", parentRef: "x", kind: .view, typeName: "UIView",
                      frame: Rect(x: 0, y: 0, width: 1000, height: 2000)),
            "leaf": Node(ref: "leaf", parentRef: "x", kind: .view, typeName: "UILabel",
                         role: "text", text: "Target",
                         frame: Rect(x: 0, y: 100, width: 1000, height: 100),
                         isInteractive: true, scroll: ScrollInfo(canScrollDown: true)),
        ]
        return Snapshot(
            capturedAtMillis: 0,
            platform: "ios",
            screen: ScreenInfo(size: Size(width: 1000, height: 2000), density: 3.0),
            rootRef: "app",
            nodes: nodes
        )
    }

    /// A children cycle among two dropped wrappers (`u1` <-> `u2`) between a
    /// kept container `k` and a kept leaf, so `keptDescendants` must cross it.
    private func childrenCycleSnapshot() -> Snapshot {
        let nodes: [String: Node] = [
            "app": Node(ref: "app", kind: .application, typeName: "Application", children: ["w"]),
            "w": Node(ref: "w", parentRef: "app", kind: .window, typeName: "UIWindow",
                      frame: Rect(x: 0, y: 0, width: 1000, height: 2000), children: ["k"]),
            "k": Node(ref: "k", parentRef: "w", kind: .view, typeName: "UIStackView",
                      testId: "host", frame: Rect(x: 0, y: 0, width: 1000, height: 2000),
                      children: ["u1"]),
            "u1": Node(ref: "u1", parentRef: "k", kind: .view, typeName: "UIView",
                       frame: Rect(x: 0, y: 0, width: 1000, height: 1000), children: ["u2"]),
            // Malformed on purpose: u2 lists u1 as a child again.
            "u2": Node(ref: "u2", parentRef: "u1", kind: .view, typeName: "UIView",
                       frame: Rect(x: 0, y: 0, width: 1000, height: 1000),
                       children: ["u1", "leaf"]),
            "leaf": Node(ref: "leaf", parentRef: "u2", kind: .view, typeName: "UILabel",
                         role: "text", text: "Deep",
                         frame: Rect(x: 0, y: 100, width: 1000, height: 100),
                         isInteractive: true),
        ]
        return Snapshot(
            capturedAtMillis: 0,
            platform: "ios",
            screen: ScreenInfo(size: Size(width: 1000, height: 2000), density: 3.0),
            rootRef: "app",
            nodes: nodes
        )
    }

    /// One ref (`dup`) listed as a child of two different parents.
    private func duplicateParentSnapshot() -> Snapshot {
        let nodes: [String: Node] = [
            "app": Node(ref: "app", kind: .application, typeName: "Application", children: ["w"]),
            "w": Node(ref: "w", parentRef: "app", kind: .window, typeName: "UIWindow",
                      frame: Rect(x: 0, y: 0, width: 1000, height: 2000), children: ["a", "b"]),
            "a": Node(ref: "a", parentRef: "w", kind: .view, typeName: "UIView",
                      frame: Rect(x: 0, y: 0, width: 1000, height: 1000), children: ["dup"]),
            "b": Node(ref: "b", parentRef: "w", kind: .view, typeName: "UIView",
                      frame: Rect(x: 0, y: 1000, width: 1000, height: 1000), children: ["dup"]),
            "dup": Node(ref: "dup", parentRef: "a", kind: .view, typeName: "UILabel",
                        role: "text", text: "Once",
                        frame: Rect(x: 0, y: 100, width: 1000, height: 100),
                        custom: ["textColor": .text("#ff112233")],
                        styleChannels: ["textColor": .viewField]),
        ]
        return Snapshot(
            capturedAtMillis: 0,
            platform: "ios",
            screen: ScreenInfo(size: Size(width: 1000, height: 2000), density: 3.0),
            rootRef: "app",
            nodes: nodes
        )
    }

    // MARK: - parentRef cycle

    func testSemanticTreeBuildReturnsOnParentCycle() {
        let tree = SemanticTree.build(from: parentCycleSnapshot())
        // The leaf's ancestor walk hit the cycle and found no kept ancestor, so
        // it hangs off the synthesized root.
        let leaf = tree.node("leaf")
        XCTAssertEqual(leaf?.parentRef, "app")
        XCTAssertNotNil(tree.root())
    }

    func testCompactObservationReturnsOnParentCycle() {
        let compact = CompactObservation.from(parentCycleSnapshot())
        XCTAssertTrue(compact.items.contains { $0.ref == "leaf" })
    }

    func testStyleObservationReturnsOnParentCycle() {
        let style = StyleObservation.from(parentCycleSnapshot())
        XCTAssertTrue(style.items.contains { $0.ref == "leaf" })
    }

    func testLabelResolutionReturnsOnParentCycle() throws {
        // The window walk for "leaf" enters the x <-> y cycle; the answer must
        // be bounded (here: the fallback all-nodes scope still finds the label).
        let hit = try Render.labelHit(parentCycleSnapshot(), "Target")
        XCTAssertEqual(hit?.node.ref, "leaf")
    }

    func testWaitProbeReturnsOnParentCycle() {
        let snapshot = parentCycleSnapshot()
        // The scrollable leaf's windowOf walk enters the cycle inside the wait
        // poll loop's screen-state probe; it must answer, not hang `act wait`.
        let probe = WaitProbe.screenState(snapshot, CompactObservation.from(snapshot))
        XCTAssertFalse(probe.digest.isEmpty)
    }

    // MARK: - children cycle

    func testSemanticTreeBuildReturnsOnChildrenCycle() {
        let tree = SemanticTree.build(from: childrenCycleSnapshot())
        // keptDescendants crossed the u1 <-> u2 cycle and still reached the
        // leaf exactly once.
        let host = tree.findByTestId("host")
        XCTAssertEqual(host?.children, ["leaf"])
    }

    func testCompactObservationReturnsOnChildrenCycleAndEmitsEachRefOnce() {
        let compact = CompactObservation.from(childrenCycleSnapshot())
        XCTAssertEqual(compact.items.filter { $0.ref == "leaf" }.count, 1)
        XCTAssertEqual(compact.items.count, Set(compact.items.map(\.ref)).count)
    }

    func testStyleObservationReturnsOnChildrenCycleAndEmitsEachRefOnce() {
        let style = StyleObservation.from(childrenCycleSnapshot())
        XCTAssertEqual(style.items.filter { $0.ref == "leaf" }.count, 1)
        XCTAssertEqual(style.items.count, Set(style.items.map(\.ref)).count)
    }

    func testLabelResolutionReturnsOnChildrenCycle() throws {
        let hit = try Render.labelHit(childrenCycleSnapshot(), "Deep")
        XCTAssertEqual(hit?.node.ref, "leaf")
    }

    // MARK: - one ref under two parents

    func testDuplicatedRefIsEmittedOnceByBothProjections() {
        let snapshot = duplicateParentSnapshot()
        // Dedup via the visit seen-set matches the document-order contract used
        // everywhere else (orderedRefs, SemanticTree.first): a node is one node
        // however many parents list it.
        XCTAssertEqual(CompactObservation.from(snapshot).items.filter { $0.ref == "dup" }.count, 1)
        XCTAssertEqual(StyleObservation.from(snapshot).items.filter { $0.ref == "dup" }.count, 1)
    }
}
