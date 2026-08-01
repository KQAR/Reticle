package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * The projection caps must SPEAK. `compact` and `style` drop everything past
 * their item caps; before this suite the drop was silent, which violates the
 * repo rule that anything unreachable declares itself (a capped list read as
 * "that was the whole screen"). And the wait digest must be built past the cap:
 * item #201 appearing is a screen change even when the rendered view stops at
 * 200 — a capped digest reports quiescence while the list is still moving.
 */
class ProjectionTruncationTest {

    private fun snapshot(buttons: Int): Snapshot {
        val children = (1..buttons).map { "b$it" }
        val root = Node(
            ref = "root", kind = NodeKind.application, typeName = "Application",
            children = children,
        )
        val nodes = (1..buttons).map {
            Node(
                ref = "b$it", parentRef = "root", kind = NodeKind.view,
                typeName = "Button", role = "button", text = "Item $it",
                frame = Rect(0.0, it * 100.0, 400.0, 90.0), isInteractive = true,
            )
        }
        return Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(size = Size(400.0, 900.0), density = 3.0),
            rootRef = "root",
            nodes = (listOf(root) + nodes).associateBy { it.ref },
        )
    }

    @Test
    fun compactCountsWhatTheCapDropped() {
        val observation = CompactObservation.from(snapshot(buttons = 5), maxItems = 3)
        assertEquals(3, observation.items.size)
        assertEquals(2, observation.truncatedItems)
    }

    @Test
    fun compactWithinTheCapReportsNothingTruncated() {
        val observation = CompactObservation.from(snapshot(buttons = 3), maxItems = 200)
        assertEquals(0, observation.truncatedItems)
    }

    @Test
    fun theCompactRenderSaysWhatItsCapDropped() {
        val rendered = Render.compact(snapshot(buttons = 205))
        assertTrue(
            rendered.lines().last().contains("5 more item(s) beyond this projection's cap"),
            "the compact render must end by saying what the cap dropped:\n${rendered.lines().last()}"
        )
    }

    @Test
    fun styleCountsWhatTheCapDropped() {
        val observation = StyleObservation.from(snapshot(buttons = 5), maxItems = 2)
        assertEquals(2, observation.items.size)
        assertEquals(3, observation.truncatedItems)
        val rendered = observation.render()
        assertTrue(
            rendered.lines().last().contains("3 more style-bearing node(s)"),
            "the style projection must say what its cap dropped:\n$rendered"
        )
    }

    @Test
    fun aChangePastTheRenderCapStillChangesTheWaitDigest() {
        // Same first 3 items; a 4th appears. Capped at 3, the digests would be
        // equal and `wait --idle` would call a moving screen quiet.
        val before = CompactObservation.from(snapshot(buttons = 3), maxItems = Int.MAX_VALUE)
        val after = CompactObservation.from(snapshot(buttons = 4), maxItems = Int.MAX_VALUE)
        assertNotEquals(WaitProbe.digestOf(before), WaitProbe.digestOf(after))
    }

    @Test
    fun focusMovingBetweenFieldsChangesTheWaitDigest() {
        fun snap(focusedRef: String): Snapshot {
            val root = Node(
                ref = "root", kind = NodeKind.application, typeName = "Application",
                children = listOf("a", "b"),
            )
            val fields = listOf("a", "b").map {
                Node(
                    ref = it, parentRef = "root", kind = NodeKind.view,
                    typeName = "EditText", role = "textField", text = "field $it",
                    frame = Rect(0.0, if (it == "a") 100.0 else 300.0, 400.0, 90.0),
                    isInteractive = true, isFocused = it == focusedRef,
                )
            }
            return Snapshot(
                capturedAtMillis = 0L,
                screen = ScreenInfo(size = Size(400.0, 900.0), density = 3.0),
                rootRef = "root",
                nodes = (listOf(root) + fields).associateBy { it.ref },
            )
        }
        val focusOnA = CompactObservation.from(snap("a"))
        val focusOnB = CompactObservation.from(snap("b"))
        assertNotEquals(
            WaitProbe.digestOf(focusOnA), WaitProbe.digestOf(focusOnB),
            "caret moving from field a to field b is a screen change: same geometry, different armed field"
        )
    }
}
