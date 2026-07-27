package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * The wheel marker: the difference between "a control whose values are pixels" and
 * "a decorative empty view", which the compact projection could not previously
 * express at all.
 *
 * The reported screen was three rectangles — no items, no selected value, no
 * `scroll:` travel, no regions — so the caller had no cue to switch tactics and
 * ended up measuring row pitch off a screenshot: four screenshot round-trips and a
 * hand-derived pixel constant for what is semantically "select 1995".
 */
class WheelMarkerTest {

    private fun snapshot(vararg nodes: Node): Snapshot = Snapshot(
        capturedAtMillis = 0L,
        screen = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0),
        rootRef = "root",
        nodes = (listOf(
            Node(
                ref = "root", kind = NodeKind.application, typeName = "Application",
                children = nodes.filter { it.parentRef == "root" }.map { it.ref },
            )
        ) + nodes).associateBy { it.ref },
    )

    private fun column(ref: String, wheel: Boolean, children: List<String> = emptyList()) = Node(
        ref = ref, parentRef = "root", kind = NodeKind.view,
        typeName = "com.example.widget.WheelView", role = "view",
        testId = ref, frame = Rect(0.0, 1377.0, 360.0, 705.0),
        isInteractive = true, suspectedWheel = wheel, children = children,
    )

    @Test
    fun aSelfDrawnWheelIsMarkedOpaque() {
        val compact = CompactObservation.from(snapshot(column("wv_first", wheel = true)))
        val item = compact.items.single { it.ref == "wv_first" }
        assertEquals("opaque", item.wheel)
        // And it says so on the line an agent actually reads.
        assertTrue(item.line().contains("wheel:opaque"), item.line())
    }

    @Test
    fun aWheelThatKeepsItsSelectionAsANodeIsMarkedSelectionOnly() {
        // Android's NumberPicker: the current value survives as a child EditText,
        // the neighbours are painted on the canvas. Collapsing the two cases would
        // understate what is readable here and overstate it for the other.
        val input = Node(
            ref = "input", parentRef = "wheel", kind = NodeKind.view,
            typeName = "android.widget.NumberPicker\$CustomEditText", role = "textField",
            resourceId = "numberpicker_input", text = "09", frame = Rect(0.0, 1600.0, 360.0, 100.0),
        )
        val compact = CompactObservation.from(
            snapshot(column("wheel", wheel = true, children = listOf("input")), input)
        )
        assertEquals("selection-only", compact.items.single { it.ref == "wheel" }.wheel)
    }

    @Test
    fun anOrdinaryContainerIsNotMarked() {
        // The marker is a hint from the widget family, and a false positive here
        // would send a caller swiping at a plain view.
        val compact = CompactObservation.from(snapshot(column("plain", wheel = false)))
        assertNull(compact.items.single { it.ref == "plain" }.wheel)
    }

    @Test
    fun theMarkerSurvivesTheWire() {
        val encoded = ReticleJson.compact.encodeToString(
            Node.serializer(),
            Node(ref = "w", kind = NodeKind.view, typeName = "WheelView", suspectedWheel = true),
        )
        assertTrue(encoded.contains("suspectedWheel"), encoded)
        // ...and stays omitted for every ordinary node, which is most of them.
        val plain = ReticleJson.compact.encodeToString(
            Node.serializer(),
            Node(ref = "p", kind = NodeKind.view, typeName = "TextView"),
        )
        assertTrue(!plain.contains("suspectedWheel"), plain)
    }
}
