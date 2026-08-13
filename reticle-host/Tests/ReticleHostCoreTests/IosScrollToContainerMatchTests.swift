import Testing
import ReticleProtocol
@testable import ReticleHostIos

/// A scroll host carries the concatenated text of every row it has realized, so a
/// `--label` for a value that is NOT on screen substring-matches the list itself.
/// Resolving that as the target is worse than failing: `found=true swipes=0` reads
/// as "it was already in view", and the tap that follows lands on the wheel.
///
/// Measured on a virtualized web date wheel on an iPhone 13 Pro Max / iOS 26:
/// `act scroll-to --label "1995"` answered `found=true settled=true swipes=0`
/// while no node in the tree carried 1995 and nothing had scrolled.
@Suite("iOS scroll-to container-match guard")
struct IosScrollToContainerMatchTests {

    private func node(
        _ ref: String, parent: String? = nil, scroll: ScrollInfo? = nil
    ) -> Node {
        Node(ref: ref, parentRef: parent, kind: .view, typeName: "UIView",
             frame: Rect(x: 0, y: 0, width: 100, height: 100), scroll: scroll)
    }

    private func snapshot(_ nodes: [Node]) -> Snapshot {
        Snapshot(
            capturedAtMillis: 0, platform: "ios",
            screen: ScreenInfo(size: Size(width: 400, height: 800), density: 3),
            rootRef: "r0",
            nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.ref, $0) }))
    }

    private let client = IosHelperClient(serial: nil)

    @Test func theContainerItselfIsNotATarget() async {
        let container = node("r10", scroll: ScrollInfo(canScrollDown: true))
        let snap = snapshot([node("r0"), container])
        #expect(client.matchedTheContainer("r10", container: container, snapshot: snap))
    }

    @Test func anAncestorOfTheContainerIsNotATarget() async {
        // A wrapper whose text is the aggregate of everything beneath it matches
        // just as readily as the list does.
        let outer = node("r5")
        let container = node("r10", parent: "r5", scroll: ScrollInfo(canScrollDown: true))
        let snap = snapshot([node("r0"), outer, container])
        #expect(client.matchedTheContainer("r5", container: container, snapshot: snap))
    }

    @Test func anotherScrollableNodeIsNotATarget() async {
        let container = node("r10", scroll: ScrollInfo(canScrollDown: true))
        let sibling = node("r20", scroll: ScrollInfo(canScrollUp: true))
        let snap = snapshot([node("r0"), container, sibling])
        #expect(client.matchedTheContainer("r20", container: container, snapshot: snap))
    }

    @Test func arowInsideTheContainerIsATarget() async {
        let container = node("r10", scroll: ScrollInfo(canScrollDown: true))
        let row = node("r11", parent: "r10")
        let snap = snapshot([node("r0"), container, row])
        #expect(!client.matchedTheContainer("r11", container: container, snapshot: snap))
    }

    @Test func anUnknownRefIsNotTreatedAsTheContainer() async {
        // Absent is not "it was the list": an unresolvable ref must not silently
        // become a refusal that hides a real miss.
        let container = node("r10", scroll: ScrollInfo(canScrollDown: true))
        let snap = snapshot([node("r0"), container])
        #expect(!client.matchedTheContainer("r99", container: container, snapshot: snap))
        #expect(!client.matchedTheContainer(nil, container: container, snapshot: snap))
    }
}
