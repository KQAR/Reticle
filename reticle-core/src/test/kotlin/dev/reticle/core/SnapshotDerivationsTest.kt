package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Tests the pure derivations from a captured snapshot: the compact observation
 * and the semantic-tree projection. Builds a tiny tree by hand:
 *
 *   app (root)
 *    └─ container (not interactive, no label)
 *        ├─ button   "Pay"  testId=pay  interactive
 *        └─ label    "Total: 9"         (text only, not interactive)
 */
class SnapshotDerivationsTest {

    private fun sampleSnapshot(): Snapshot {
        val nodes = linkedMapOf(
            "app" to Node(ref = "app", kind = NodeKind.application, typeName = "Application", children = listOf("box")),
            "box" to Node(
                ref = "box", parentRef = "app", kind = NodeKind.view, typeName = "FrameLayout",
                role = "container", children = listOf("pay", "label"),
            ),
            "pay" to Node(
                ref = "pay", parentRef = "box", kind = NodeKind.view, typeName = "android.widget.Button",
                role = "button", text = "Pay", testId = "pay", isInteractive = true,
                frame = Rect(0.0, 0.0, 200.0, 80.0),
            ),
            "label" to Node(
                ref = "label", parentRef = "box", kind = NodeKind.view, typeName = "android.widget.TextView",
                role = "text", text = "Total: 9", isInteractive = false,
                frame = Rect(0.0, 90.0, 200.0, 40.0),
            ),
        )
        return Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0, interfaceStyle = "light"),
            rootRef = "app",
            nodes = nodes,
        )
    }

    @Test
    fun compact_keepsInteractiveAndLabelled_dropsBareContainers() {
        val compact = CompactObservation.from(sampleSnapshot())
        val refs = compact.items.map { it.ref }.toSet()
        assertTrue("pay" in refs, "interactive button must be kept")
        assertTrue("label" in refs, "labelled text must be kept")
        assertFalse("box" in refs, "bare container must be dropped")
        assertFalse("app" in refs, "application root must be dropped")
    }

    @Test
    fun compact_line_rendersSelectorAndState() {
        val compact = CompactObservation.from(sampleSnapshot())
        val payLine = compact.items.first { it.ref == "pay" }.line()
        assertTrue(payLine.contains("#pay"), "testId selector should render as #pay: $payLine")
        assertTrue(payLine.contains("Pay"))
        assertTrue(payLine.contains("tappable"))
    }

    @Test
    fun compact_respectsMaxItems() {
        val compact = CompactObservation.from(sampleSnapshot(), maxItems = 1)
        assertEquals(1, compact.items.size)
    }

    @Test
    fun semanticTree_keepsSignalNodes_findBySelectors() {
        val tree = SemanticTree.build(sampleSnapshot())
        // button is interactive + has text + testId -> kept and findable
        val pay = assertNotNull(tree.findByTestId("pay"))
        assertEquals("Pay", pay.label)
        // label has text -> kept
        assertNotNull(tree.nodes.values.firstOrNull { it.label == "Total: 9" })
        // bare container carries no targeting signal -> dropped
        assertNull(tree.nodes["box"])
    }

    @Test
    fun uiReport_derivesEveryViewFromOneSnapshot() {
        val snapshot = sampleSnapshot()
        val report = UiReport.from(snapshot)

        assertEquals(snapshot, report.snapshot)
        assertEquals(snapshot.capturedAtMillis, report.compact.capturedAtMillis)
        assertNotNull(report.semantics.findByTestId("pay"))
        assertTrue(report.compact.items.any { it.ref == "pay" })
    }
}
