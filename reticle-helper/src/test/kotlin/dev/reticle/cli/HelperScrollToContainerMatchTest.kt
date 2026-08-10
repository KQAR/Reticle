package dev.reticle.cli

import dev.reticle.core.Node
import dev.reticle.core.NodeKind
import dev.reticle.core.Rect
import dev.reticle.core.ScreenInfo
import dev.reticle.core.ScrollInfo
import dev.reticle.core.Size
import dev.reticle.core.Snapshot
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * A scroll host carries the concatenated text of every row it has bound, so a
 * `--label` for a value that is NOT on screen substring-matches the list itself.
 * Resolving that as the target is worse than failing: `found=true swipes=0` reads
 * as "it was already in view", and the tap that follows lands on the list.
 *
 * Measured on iOS against a virtualized web date wheel — `scroll-to --label
 * "1995"` answered `found=true settled=true swipes=0` while no node carried 1995
 * and nothing had scrolled. The same shared resolution runs here, so the hole was
 * here too; this pins the guard on both sides (the twin is
 * `IosScrollToContainerMatchTests`).
 */
class HelperScrollToContainerMatchTest {

    private fun node(ref: String, parent: String? = null, scroll: ScrollInfo? = null) = Node(
        ref = ref,
        parentRef = parent,
        kind = NodeKind.view,
        typeName = "android.view.View",
        frame = Rect(0.0, 0.0, 100.0, 100.0),
        scroll = scroll,
    )

    private fun snapshot(vararg nodes: Node) = Snapshot(
        capturedAtMillis = 0L,
        screen = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0),
        rootRef = "r0",
        nodes = linkedMapOf(*nodes.map { it.ref to it }.toTypedArray()),
    )

    @Test
    fun theContainerItselfIsNotATarget() {
        val container = node("r10", scroll = ScrollInfo(canScrollDown = true))
        assertTrue(
            HelperScrollTo.matchedTheContainer("r10", container, snapshot(node("r0"), container)),
        )
    }

    @Test
    fun anAncestorOfTheContainerIsNotATarget() {
        val outer = node("r5")
        val container = node("r10", parent = "r5", scroll = ScrollInfo(canScrollDown = true))
        assertTrue(
            HelperScrollTo.matchedTheContainer("r5", container, snapshot(node("r0"), outer, container)),
        )
    }

    @Test
    fun anotherScrollableNodeIsNotATarget() {
        val container = node("r10", scroll = ScrollInfo(canScrollDown = true))
        val sibling = node("r20", scroll = ScrollInfo(canScrollUp = true))
        assertTrue(
            HelperScrollTo.matchedTheContainer("r20", container, snapshot(node("r0"), container, sibling)),
        )
    }

    @Test
    fun aRowInsideTheContainerIsATarget() {
        val container = node("r10", scroll = ScrollInfo(canScrollDown = true))
        val row = node("r11", parent = "r10")
        assertFalse(
            HelperScrollTo.matchedTheContainer("r11", container, snapshot(node("r0"), container, row)),
        )
    }

    @Test
    fun anUnknownRefIsNotTreatedAsTheContainer() {
        // Absent is not "it was the list": an unresolvable ref must not become a
        // refusal that hides a real miss.
        val container = node("r10", scroll = ScrollInfo(canScrollDown = true))
        val snap = snapshot(node("r0"), container)
        assertFalse(HelperScrollTo.matchedTheContainer("r99", container, snap))
        assertFalse(HelperScrollTo.matchedTheContainer(null, container, snap))
    }
}
