package dev.reticle.agent

import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import dev.reticle.core.CompactObservation
import dev.reticle.core.NodeKind
import dev.reticle.core.SemanticTree
import dev.reticle.core.Snapshot
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The view walk itself — what every command ultimately reads, and the largest
 * piece of the agent that had no coverage.
 *
 * A unit-test process has no attached window, so the capture takes its roots as
 * an argument (the default is the live `WindowManagerGlobal` enumeration, which
 * is what production uses). That one seam makes the whole walk testable over a
 * hand-built hierarchy: refs, parent/child links, screen-space frames, the
 * visibility filter, and the projections derived from the same capture. The iOS
 * twin (`SnapshotCaptureTests`) asserts the same shape.
 */
@RunWith(RobolectricTestRunner::class)
class SnapshotCaptureTest {

    private val context = RuntimeEnvironment.getApplication()

    /** The probe registry is process-global; a test that registers one would
     *  otherwise leak an extra application child into every test after it. */
    @Before
    fun resetProbes() = ReticleProbeRegistry.clear()

    /** A screen: a labelled button, a text row, and a gone banner. */
    private fun screen(): ViewGroup {
        val root = FrameLayout(context)
        val column = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }

        val total = TextView(context).apply {
            tag = "checkout.total"
            text = "Total: $42"
        }
        val pay = Button(context).apply {
            tag = "checkout.payButton"
            text = "Pay now"
            isClickable = true
        }
        val banner = TextView(context).apply {
            tag = "checkout.debugBanner"
            text = "DEBUG BUILD"
            visibility = View.GONE
        }
        column.addView(total)
        column.addView(pay)
        column.addView(banner)
        root.addView(column)

        val spec = View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY)
        root.measure(spec, View.MeasureSpec.makeMeasureSpec(2400, View.MeasureSpec.EXACTLY))
        root.layout(0, 0, 1080, 2400)
        return root
    }

    private fun capture(vararg roots: View): Snapshot =
        SnapshotCapture(context) { roots.toList() }.capture()

    @Test
    fun theTreeIsRootedAtAnApplicationNodeWithOneChildPerWindow() {
        val snapshot = capture(screen(), screen())
        val root = assertNotNull(snapshot.root())
        assertEquals(NodeKind.application, root.kind)
        assertEquals(2, root.children.size)
        for (ref in root.children) {
            assertEquals(NodeKind.window, snapshot.nodes[ref]?.kind, "a window root must be marked as one")
        }
        assertEquals("android", snapshot.platform)
    }

    @Test
    fun everyNodeIsReachableFromTheRootAndPointsBackAtItsParent() {
        val snapshot = capture(screen())
        val seen = HashSet<String>()
        fun walk(ref: String) {
            val node = snapshot.nodes[ref] ?: return
            if (!seen.add(ref)) return
            for (child in node.children) {
                assertEquals(ref, snapshot.nodes[child]?.parentRef, "child $child disagrees about its parent")
                walk(child)
            }
        }
        walk(snapshot.rootRef)
        assertEquals(snapshot.nodes.size, seen.size, "the walk left orphan nodes in the map")
    }

    @Test
    fun aStringTagBecomesTheTestIdAndTheNodeKeepsItsRoleAndText() {
        val snapshot = capture(screen())
        val pay = assertNotNull(snapshot.firstNode { it.testId == "checkout.payButton" })
        assertEquals("Pay now", pay.text)
        assertTrue(pay.isInteractive, "a clickable Button is the canonical tappable node")
        assertNotNull(pay.frame)
    }

    @Test
    fun framesAreInScreenCoordinatesSoATapPointNeedsNoConversion() {
        val root = screen()
        val snapshot = capture(root)
        val pay = assertNotNull(snapshot.firstNode { it.testId == "checkout.payButton" })
        val frame = assertNotNull(pay.frame)

        val loc = IntArray(2)
        val view = root.findViewWithTag<View>("checkout.payButton")
        view.getLocationOnScreen(loc)
        assertEquals(loc[0].toDouble(), frame.x, 0.5)
        assertEquals(loc[1].toDouble(), frame.y, 0.5)
        assertEquals(view.width.toDouble(), frame.width, 0.5)
    }

    @Test
    fun aGoneViewIsCapturedAndMarkedRatherThanDropped() {
        // The snapshot is the full record; the FILTER lives in the compact
        // projection. Dropping it here would leave `ui node` unable to answer
        // "is that banner still in the tree".
        val snapshot = capture(screen())
        val banner = assertNotNull(snapshot.firstNode { it.testId == "checkout.debugBanner" })
        assertFalse(banner.isVisible)

        val compact = CompactObservation.from(snapshot)
        assertFalse(
            compact.items.any { it.testId == "checkout.debugBanner" },
            "compact is for acting now, so an invisible node must not appear in it",
        )
        assertTrue(compact.items.any { it.testId == "checkout.payButton" })
    }

    @Test
    fun twoCapturesOfTheSameTreeAgreeOnEveryRef() {
        // Refs are positional and `viewByRef` re-resolves one by replaying the
        // walk, so numbering that moved between two identical captures would let
        // `mutate --ref` patch a different view than the caller read.
        val root = screen()
        val first = capture(root)
        val second = capture(root)
        assertEquals(
            first.nodes.mapValues { (_, n) -> n.testId ?: n.typeName },
            second.nodes.mapValues { (_, n) -> n.testId ?: n.typeName },
        )
    }

    @Test
    fun aRefResolvesBackToTheViewItWasTakenFrom() {
        val root = screen()
        val capture = SnapshotCapture(context) { listOf(root) }
        val snapshot = capture.capture()
        val payRef = assertNotNull(snapshot.firstNode { it.testId == "checkout.payButton" }).ref
        val view = assertNotNull(capture.viewByRef(payRef))
        assertEquals("Pay now", (view as TextView).text.toString())
    }

    @Test
    fun screenInfoCarriesTheDensityAndFontScaleTheStyleProjectionDividesBy() {
        val snapshot = capture(screen())
        assertTrue(snapshot.screen.size.width > 0)
        assertTrue(snapshot.screen.density > 0)
        // Without fontScale an sp figure cannot be told apart from "the user
        // enlarged text", so the style projection refuses to report sp at all.
        assertNotNull(snapshot.screen.fontScale)
    }

    @Test
    fun theSemanticProjectionKeepsTargetableNodesAndStaysConnected() {
        val snapshot = capture(screen())
        val semantic = SemanticTree.build(snapshot)
        assertNotNull(semantic.nodes.values.firstOrNull { it.testId == "checkout.payButton" })
        for (node in semantic.nodes.values) {
            val parent = node.parentRef ?: continue
            assertNotNull(semantic.nodes[parent], "semantic node ${node.ref} points at a dropped parent")
        }
    }

    @Test
    fun anEmptyRootListStillProducesAWellFormedSnapshot() {
        // Degrade to an empty screen rather than to a broken document: reading
        // "nothing attached" must not need a special case.
        val snapshot = SnapshotCapture(context) { emptyList() }.capture()
        assertEquals(NodeKind.application, snapshot.root()?.kind)
        // No windows — the only children an application node can still have are
        // app-authored probes, which are metadata rather than screen content.
        assertTrue(snapshot.nodes.values.none { it.kind == NodeKind.window })
        assertTrue(CompactObservation.from(snapshot).items.none { it.frame != null })
    }

    @Test
    fun anAppAuthoredProbeIsCapturedAsAChildOfTheApplication() {
        // The app-authored channel: metadata a host app publishes for its own
        // screens, addressable by testId like any other node.
        Reticle.registerProbe("checkout.state", mapOf("cart" to "3 items"))
        run {
            val snapshot = capture(screen())
            val probe = assertNotNull(snapshot.firstNode { it.testId == "checkout.state" })
            assertEquals(NodeKind.probe, probe.kind)
            assertEquals(snapshot.rootRef, probe.parentRef)
            assertNull(probe.frame, "a probe is metadata, not geometry - it has no rect to tap")
        }
    }
}
