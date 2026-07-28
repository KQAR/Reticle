package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Window scoping and per-item window attribution — the two halves of reading a
 * STACKED screen.
 *
 * A form pushed over a still-live host page puts both windows in one capture, and
 * every flat projection then interleaves them by geometry: framework ids appear
 * twice, and the fields of the screen being driven end up scattered among
 * unrelated content. Measured on a real form, the relevant nodes were about a
 * third of a 99-line outline.
 */
class WindowScopeTest {

    /** Two live windows: a host page, and a form pushed over it. */
    private fun stacked(): Snapshot {
        fun content(ref: String, window: String, y: Double, testId: String) = Node(
            ref = ref, parentRef = window, kind = NodeKind.view,
            typeName = "android.widget.TextView", role = "text",
            testId = testId, text = testId, frame = Rect(0.0, y, 1000.0, 100.0),
            isInteractive = true,
        )
        val nodes = linkedMapOf(
            "app" to Node(ref = "app", kind = NodeKind.application, typeName = "Application", children = listOf("w1", "w2")),
            // Bottom-most first, as the platform reports them.
            "w1" to Node(
                ref = "w1", parentRef = "app", kind = NodeKind.window,
                typeName = "com.android.internal.policy.DecorView",
                frame = Rect(0.0, 0.0, 1000.0, 2000.0), children = listOf("host.a", "host.b"),
            ),
            "w2" to Node(
                ref = "w2", parentRef = "app", kind = NodeKind.window,
                typeName = "com.android.internal.policy.DecorView",
                frame = Rect(0.0, 0.0, 1000.0, 2000.0), children = listOf("form.a", "form.b"),
            ),
            // Interleaved by geometry on purpose — that is the reported symptom.
            "host.a" to content("host.a", "w1", 150.0, "loanCard"),
            "form.a" to content("form.a", "w2", 100.0, "firstName"),
            "host.b" to content("host.b", "w1", 400.0, "ivBg"),
            "form.b" to content("form.b", "w2", 300.0, "lastName"),
        )
        return Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(size = Size(1000.0, 2000.0), density = 3.0),
            rootRef = "app",
            nodes = nodes,
        )
    }

    @Test
    fun windowsAreReportedBottomMostFirstAndTheTopIsNamed() {
        val snapshot = stacked()
        assertEquals(listOf("w1", "w2"), snapshot.windowRefs())
        assertEquals("w2", snapshot.topWindowRef())
    }

    @Test
    fun everyNodeKnowsWhichWindowItIsIn() {
        val snapshot = stacked()
        assertEquals("w2", snapshot.windowRefOf("form.a"))
        assertEquals("w1", snapshot.windowRefOf("host.b"))
        // The application root is above every window and belongs to none.
        assertNull(snapshot.windowRefOf("app"))
    }

    @Test
    fun scopingToTopKeepsOnlyTheScreenBeingDriven() {
        val scoped = stacked().scopedToWindow(Snapshot.TOP_WINDOW)!!
        assertEquals(setOf("app", "w2", "form.a", "form.b"), scoped.nodes.keys)
        // The root stays, so the tree is still walkable from rootRef — it just has
        // one window under it now.
        assertEquals(listOf("w2"), scoped.root()!!.children)
    }

    @Test
    fun scopingByExplicitRefWorksToo() {
        val scoped = stacked().scopedToWindow("w1")!!
        assertEquals(setOf("app", "w1", "host.a", "host.b"), scoped.nodes.keys)
    }

    @Test
    fun anUnknownWindowIsNullRatherThanEverything() {
        // Silently rendering the whole capture would look like the scope had been
        // applied and found the screen busy.
        assertNull(stacked().scopedToWindow("nope"))
    }

    @Test
    fun compactAttributesEveryItemToItsWindow() {
        val compact = CompactObservation.from(stacked())
        assertEquals("w2", compact.items.first { it.testId == "firstName" }.windowRef)
        assertEquals("w1", compact.items.first { it.testId == "loanCard" }.windowRef)
    }

    @Test
    fun scopingRemovesTheBackgroundWindowFromCompactEntirely() {
        val compact = CompactObservation.from(stacked().scopedToWindow(Snapshot.TOP_WINDOW)!!)
        assertEquals(listOf("firstName", "lastName"), compact.items.mapNotNull { it.testId })
        // And with nothing stacked above, nothing is reported as occluded by a
        // window either — the marker that used to be the only hint here.
        assertTrue(compact.items.all { it.occludedBy == null })
    }

    @Test
    fun aSingleWindowCaptureIsUnaffected() {
        val scoped = stacked().scopedToWindow("w2")!!
        assertEquals(scoped.nodes.keys, scoped.scopedToWindow(Snapshot.TOP_WINDOW)!!.nodes.keys)
    }
}
