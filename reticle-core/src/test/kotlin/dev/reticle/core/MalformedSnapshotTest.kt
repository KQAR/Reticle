package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

/**
 * Malformed snapshots must produce a bounded, deterministic answer — never a
 * hang or a stack overflow.
 *
 * A snapshot is not always the agent's own fresh capture: it can be loaded from
 * disk (`--snapshot file`) or produced by a buggy agent build, so a parentRef
 * cycle, a children cycle, or one ref listed under two parents are legitimate
 * inputs to every derivation. The assertion in most of these tests is simply
 * that the call RETURNS: before the guards, `SemanticTree.build` spun forever
 * in `nearestKeptAncestor`, `CompactObservation.from` recursed until stack
 * overflow, and the `windowOf` walk inside the wait poll loop hung `act wait`.
 *
 * The Swift twin is `MalformedSnapshotTests` in reticle-swift — the two must
 * stay aligned, like every other derivation pair in this repo.
 */
class MalformedSnapshotTest {

    /**
     * A parentRef cycle among two dropped wrappers (`x` <-> `y`), below a real
     * window. `leaf` is a kept node whose ancestor walk enters the cycle.
     */
    private fun parentCycleSnapshot(): Snapshot {
        val nodes = linkedMapOf(
            "app" to Node(ref = "app", kind = NodeKind.application, typeName = "Application", children = listOf("w")),
            "w" to Node(
                ref = "w", parentRef = "app", kind = NodeKind.window, typeName = "DecorView",
                frame = Rect(0.0, 0.0, 1000.0, 2000.0), children = listOf("x"),
            ),
            // Malformed on purpose: x's parentRef points into a cycle with y,
            // not at the window that actually lists it as a child.
            "x" to Node(
                ref = "x", parentRef = "y", kind = NodeKind.view, typeName = "FrameLayout",
                frame = Rect(0.0, 0.0, 1000.0, 2000.0), children = listOf("leaf"),
            ),
            "y" to Node(
                ref = "y", parentRef = "x", kind = NodeKind.view, typeName = "FrameLayout",
                frame = Rect(0.0, 0.0, 1000.0, 2000.0),
            ),
            "leaf" to Node(
                ref = "leaf", parentRef = "x", kind = NodeKind.view, typeName = "android.widget.TextView",
                role = "text", text = "Target", frame = Rect(0.0, 100.0, 1000.0, 100.0),
                isInteractive = true, scroll = ScrollInfo(canScrollDown = true),
            ),
        )
        return Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(size = Size(1000.0, 2000.0), density = 3.0),
            rootRef = "app",
            nodes = nodes,
        )
    }

    /**
     * A children cycle among two dropped wrappers (`u1` <-> `u2`) between a kept
     * container `k` and a kept leaf, so `keptDescendants` must cross the cycle.
     */
    private fun childrenCycleSnapshot(): Snapshot {
        val nodes = linkedMapOf(
            "app" to Node(ref = "app", kind = NodeKind.application, typeName = "Application", children = listOf("w")),
            "w" to Node(
                ref = "w", parentRef = "app", kind = NodeKind.window, typeName = "DecorView",
                frame = Rect(0.0, 0.0, 1000.0, 2000.0), children = listOf("k"),
            ),
            "k" to Node(
                ref = "k", parentRef = "w", kind = NodeKind.view, typeName = "LinearLayout",
                testId = "host", frame = Rect(0.0, 0.0, 1000.0, 2000.0), children = listOf("u1"),
            ),
            "u1" to Node(
                ref = "u1", parentRef = "k", kind = NodeKind.view, typeName = "FrameLayout",
                frame = Rect(0.0, 0.0, 1000.0, 1000.0), children = listOf("u2"),
            ),
            // Malformed on purpose: u2 lists u1 as a child again.
            "u2" to Node(
                ref = "u2", parentRef = "u1", kind = NodeKind.view, typeName = "FrameLayout",
                frame = Rect(0.0, 0.0, 1000.0, 1000.0), children = listOf("u1", "leaf"),
            ),
            "leaf" to Node(
                ref = "leaf", parentRef = "u2", kind = NodeKind.view, typeName = "android.widget.TextView",
                role = "text", text = "Deep", frame = Rect(0.0, 100.0, 1000.0, 100.0),
                isInteractive = true,
            ),
        )
        return Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(size = Size(1000.0, 2000.0), density = 3.0),
            rootRef = "app",
            nodes = nodes,
        )
    }

    /** One ref (`dup`) listed as a child of two different parents. */
    private fun duplicateParentSnapshot(): Snapshot {
        val nodes = linkedMapOf(
            "app" to Node(ref = "app", kind = NodeKind.application, typeName = "Application", children = listOf("w")),
            "w" to Node(
                ref = "w", parentRef = "app", kind = NodeKind.window, typeName = "DecorView",
                frame = Rect(0.0, 0.0, 1000.0, 2000.0), children = listOf("a", "b"),
            ),
            "a" to Node(
                ref = "a", parentRef = "w", kind = NodeKind.view, typeName = "FrameLayout",
                frame = Rect(0.0, 0.0, 1000.0, 1000.0), children = listOf("dup"),
            ),
            "b" to Node(
                ref = "b", parentRef = "w", kind = NodeKind.view, typeName = "FrameLayout",
                frame = Rect(0.0, 1000.0, 1000.0, 1000.0), children = listOf("dup"),
            ),
            "dup" to Node(
                ref = "dup", parentRef = "a", kind = NodeKind.view, typeName = "android.widget.TextView",
                role = "text", text = "Once", frame = Rect(0.0, 100.0, 1000.0, 100.0),
                custom = mapOf("textColor" to MetadataValue.Text("#ff112233")),
                styleChannels = mapOf("textColor" to StyleChannel.viewField),
            ),
        )
        return Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(size = Size(1000.0, 2000.0), density = 3.0),
            rootRef = "app",
            nodes = nodes,
        )
    }

    // ---- parentRef cycle -------------------------------------------------

    @Test
    fun semanticTreeBuildReturnsOnParentCycle() {
        val tree = SemanticTree.build(parentCycleSnapshot())
        // The leaf's ancestor walk hit the cycle and found no kept ancestor, so
        // it hangs off the synthesized root.
        val leaf = assertNotNull(tree.node("leaf"))
        assertEquals("app", leaf.parentRef)
        assertNotNull(tree.root())
    }

    @Test
    fun compactObservationReturnsOnParentCycle() {
        val compact = CompactObservation.from(parentCycleSnapshot())
        assertTrue(compact.items.any { it.ref == "leaf" })
    }

    @Test
    fun styleObservationReturnsOnParentCycle() {
        val style = StyleObservation.from(parentCycleSnapshot())
        assertTrue(style.items.any { it.ref == "leaf" })
    }

    @Test
    fun labelResolutionReturnsOnParentCycle() {
        val snapshot = parentCycleSnapshot()
        val resolver = SelectorResolver(snapshot, SemanticTree.build(snapshot))
        // The window walk for "leaf" enters the x <-> y cycle; the answer must
        // be bounded (here: the fallback all-nodes scope still finds the label).
        val resolved = assertNotNull(resolver.resolve(Selector(label = "Target")))
        assertEquals("leaf", resolved.ref)
    }

    @Test
    fun waitProbeReturnsOnParentCycle() {
        val snapshot = parentCycleSnapshot()
        // The scrollable leaf's windowOf walk enters the cycle inside the wait
        // poll loop's screen-state probe; it must answer, not hang `act wait`.
        val probe = WaitProbe.screenState(snapshot, CompactObservation.from(snapshot))
        assertTrue(probe.digest.isNotEmpty())
    }

    // ---- children cycle --------------------------------------------------

    @Test
    fun semanticTreeBuildReturnsOnChildrenCycle() {
        val tree = SemanticTree.build(childrenCycleSnapshot())
        // keptDescendants crossed the u1 <-> u2 cycle and still reached the leaf
        // exactly once.
        val host = assertNotNull(tree.findByTestId("host"))
        assertEquals(listOf("leaf"), host.children)
    }

    @Test
    fun compactObservationReturnsOnChildrenCycleAndEmitsEachRefOnce() {
        val compact = CompactObservation.from(childrenCycleSnapshot())
        assertEquals(1, compact.items.count { it.ref == "leaf" })
        assertEquals(compact.items.size, compact.items.map { it.ref }.distinct().size)
    }

    @Test
    fun styleObservationReturnsOnChildrenCycleAndEmitsEachRefOnce() {
        val style = StyleObservation.from(childrenCycleSnapshot())
        assertEquals(1, style.items.count { it.ref == "leaf" })
        assertEquals(style.items.size, style.items.map { it.ref }.distinct().size)
    }

    @Test
    fun labelResolutionReturnsOnChildrenCycle() {
        val snapshot = childrenCycleSnapshot()
        val resolver = SelectorResolver(snapshot, SemanticTree.build(snapshot))
        val resolved = assertNotNull(resolver.resolve(Selector(label = "Deep")))
        assertEquals("leaf", resolved.ref)
    }

    // ---- one ref under two parents ----------------------------------------

    @Test
    fun duplicatedRefIsEmittedOnceByBothProjections() {
        val snapshot = duplicateParentSnapshot()
        // Dedup via the visit seen-set matches the document-order contract used
        // everywhere else (refsInDocumentOrder, SemanticTree.firstNode): a node
        // is one node however many parents list it.
        assertEquals(1, CompactObservation.from(snapshot).items.count { it.ref == "dup" })
        assertEquals(1, StyleObservation.from(snapshot).items.count { it.ref == "dup" })
    }
}
