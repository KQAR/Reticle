package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Folding anonymous layers into the node they wrap.
 *
 * The shape measured on an iOS simulator: one `UIPickerView` row is three compact
 * lines — the cell, the label, and the cell's content view — of which two are
 * anonymous rectangles at the same place. 86 lines for a two-column wheel, 46 of
 * them carrying nothing an agent can act on.
 *
 * Every test here is really one question: does the fold keep the projection
 * *true*? A folded layer must add nothing the survivor doesn't already say, and
 * anything that could be a distinct target must survive.
 */
class CompactCollapseTest {

    private fun snapshot(vararg nodes: Node): Snapshot {
        val root = Node(
            ref = "root", kind = NodeKind.application, typeName = "Application",
            children = nodes.filter { it.parentRef == "root" }.map { it.ref },
        )
        return Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(size = Size(400.0, 900.0), density = 3.0),
            rootRef = "root",
            nodes = (listOf(root) + nodes).associateBy { it.ref },
        )
    }

    /** One picker row as UIKit really builds it: cell > (label, contentView). */
    private fun pickerRow(): Snapshot = snapshot(
        Node(
            ref = "cell", parentRef = "root", kind = NodeKind.view,
            typeName = "UIPickerTableViewTitledCell", role = "container",
            frame = Rect(41.0, 487.0, 165.0, 24.0), isInteractive = true,
            children = listOf("label", "content"),
        ),
        Node(
            ref = "label", parentRef = "cell", kind = NodeKind.view,
            typeName = "UILabel", role = "text", text = "09",
            frame = Rect(50.0, 487.0, 147.0, 24.0),
        ),
        Node(
            ref = "content", parentRef = "cell", kind = NodeKind.view,
            typeName = "UITableViewCellContentView", role = "view",
            frame = Rect(41.0, 487.0, 165.0, 24.0), isInteractive = true,
        ),
    )

    @Test
    fun aPickerRowBecomesOneLine() {
        val compact = CompactObservation.from(pickerRow())
        assertEquals(listOf("label"), compact.items.map { it.ref })
        assertEquals(2, compact.collapsedWrappers)
    }

    @Test
    fun theSurvivorInheritsTheTappabilityItAbsorbed() {
        // Without this the row would read inert: the UILabel is not interactive,
        // the two layers that were are gone, and an agent would skip a tappable row.
        val item = CompactObservation.from(pickerRow()).items.single()
        assertTrue(item.isInteractive, item.line())
    }

    @Test
    fun aWrapperWithItsOwnIdOutlivesTheFold() {
        // The compound-field shape (#142): the unique testId is on the WRAPPER and
        // the input inside carries a generic one. Folding the wrapper away would
        // delete the only handle the caller has.
        val compact = CompactObservation.from(
            snapshot(
                Node(
                    ref = "wrap", parentRef = "root", kind = NodeKind.view,
                    typeName = "LinearLayout", role = "container", testId = "form.firstName",
                    frame = Rect(0.0, 100.0, 200.0, 60.0), isInteractive = true,
                    children = listOf("input"),
                ),
                Node(
                    ref = "input", parentRef = "wrap", kind = NodeKind.view,
                    typeName = "EditText", role = "textField", text = "Ada",
                    frame = Rect(10.0, 100.0, 180.0, 60.0), isInteractive = true, isFocusable = true,
                ),
            )
        )
        assertEquals(listOf("wrap", "input"), compact.items.map { it.ref })
        assertEquals(0, compact.collapsedWrappers)
    }

    @Test
    fun aPageSizedContainerIsNotAWrapperOfALabelInsideIt() {
        // Containment alone is not enough, or every screen would fold into its
        // first label. The layer has to HUG what it wraps.
        val compact = CompactObservation.from(
            snapshot(
                Node(
                    ref = "page", parentRef = "root", kind = NodeKind.view,
                    typeName = "FrameLayout", role = "container",
                    frame = Rect(0.0, 0.0, 400.0, 900.0), isInteractive = true,
                    children = listOf("title"),
                ),
                Node(
                    ref = "title", parentRef = "page", kind = NodeKind.view,
                    typeName = "TextView", role = "text", text = "Hello",
                    frame = Rect(20.0, 440.0, 100.0, 20.0),
                ),
            )
        )
        assertEquals(listOf("page", "title"), compact.items.map { it.ref })
    }

    @Test
    fun anUnrelatedOverlayIsNeverMerged() {
        // Two things that merely overlap are two targets. Only an ancestor,
        // descendant or sibling can be a wrapper.
        val compact = CompactObservation.from(
            snapshot(
                Node(
                    ref = "a", parentRef = "root", kind = NodeKind.view, typeName = "FrameLayout",
                    role = "container", frame = Rect(0.0, 0.0, 100.0, 40.0), isInteractive = true,
                ),
                Node(
                    ref = "bParent", parentRef = "root", kind = NodeKind.view, typeName = "FrameLayout",
                    role = "container", frame = Rect(0.0, 0.0, 300.0, 300.0), children = listOf("b"),
                    testId = "other.branch",
                ),
                Node(
                    ref = "b", parentRef = "bParent", kind = NodeKind.view, typeName = "TextView",
                    role = "text", text = "Overlapping", frame = Rect(5.0, 5.0, 90.0, 30.0),
                ),
            )
        )
        assertTrue("a" in compact.items.map { it.ref }, compact.items.map { it.ref }.toString())
    }

    @Test
    fun aScrollableOrWheelLayerIsNeverFolded() {
        // `scroll:` and `wheel:` are the answer to "why is this selector missing"
        // and "how do I drive this" — they must not vanish into a child's line.
        val compact = CompactObservation.from(
            snapshot(
                Node(
                    ref = "list", parentRef = "root", kind = NodeKind.view, typeName = "RecyclerView",
                    role = "scrollView", frame = Rect(0.0, 0.0, 200.0, 100.0), isInteractive = true,
                    scroll = ScrollInfo(canScrollUp = false, canScrollDown = true),
                    children = listOf("row"),
                ),
                Node(
                    ref = "row", parentRef = "list", kind = NodeKind.view, typeName = "TextView",
                    role = "text", text = "Row 1", frame = Rect(0.0, 0.0, 200.0, 100.0),
                ),
            )
        )
        assertEquals(listOf("list", "row"), compact.items.map { it.ref })
    }

    @Test
    fun theFocusedLayerStaysPutEvenWhenItIsAnonymous() {
        // "This node holds focus" is a precise claim about ONE node; migrating it
        // onto a neighbour would be a small, confident lie.
        val compact = CompactObservation.from(
            snapshot(
                Node(
                    ref = "host", parentRef = "root", kind = NodeKind.view, typeName = "WebView",
                    role = "container", frame = Rect(0.0, 0.0, 200.0, 60.0),
                    isInteractive = true, isFocused = true, children = listOf("inner"),
                ),
                Node(
                    ref = "inner", parentRef = "host", kind = NodeKind.view, typeName = "TextView",
                    role = "text", text = "typed", frame = Rect(5.0, 0.0, 190.0, 60.0),
                ),
            )
        )
        assertEquals(listOf("host", "inner"), compact.items.map { it.ref })
    }

    @Test
    fun aTreeWithNothingToFoldIsUntouched() {
        val plain = snapshot(
            Node(
                ref = "b", parentRef = "root", kind = NodeKind.view, typeName = "Button",
                role = "button", testId = "pay", text = "Pay",
                frame = Rect(0.0, 0.0, 100.0, 40.0), isInteractive = true,
            )
        )
        val compact = CompactObservation.from(plain)
        assertEquals(listOf("b"), compact.items.map { it.ref })
        assertEquals(0, compact.collapsedWrappers)
    }
}
