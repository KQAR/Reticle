package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * An in-page dialog is a cover with no window of its own.
 *
 * Measured on a real hybrid form: with the app's own
 * action sheet open, every field behind it was projected as an ordinary `tappable`
 * node with no occluder, and `act type --label "Monthly income"` tapped through
 * the backdrop, selected an option inside the sheet, and reported the type as
 * dispatched. A wrong thing changed convincingly, which is the failure shape the
 * `occluded-by:` channel exists to prevent.
 *
 * The cause was one rule applied to two opposite defaults: a cover had to be
 * `isInteractive` to count, which is right for a native view (Android hands the
 * touch to the topmost child that consumes it) and wrong for a DOM element, which
 * eats the click wherever its box lies unless the page said `pointer-events: none`.
 * A framework sheet's backdrop publishes no role, no tabindex and no handler.
 */
class DomOverlayOcclusionTest {
    private fun dom(
        ref: String,
        parentRef: String,
        role: String,
        frame: Rect,
        children: List<String> = emptyList(),
        interactive: Boolean = false,
        text: String? = null,
        styles: Map<String, String> = emptyMap(),
    ): Node = Node(
        ref = ref,
        parentRef = parentRef,
        kind = NodeKind.domNode,
        typeName = "DOMElement",
        role = role,
        text = text,
        frame = frame,
        isInteractive = interactive,
        children = children,
        custom = (mapOf("domTag" to role) + styles).mapValues { MetadataValue.Text(it.value) },
    )

    /**
     * A page whose sheet is open: `body` has the form, then the backdrop, then the
     * sheet — later siblings, which is paint order. The backdrop is full-screen,
     * `position: fixed`, and paints `rgba(0,0,0,.7)`; the sheet only covers the
     * bottom half, so the form field at the top is under the BACKDROP alone. That is
     * the case a descendant-of-the-cover check cannot see.
     */
    private fun sheetOpenSnapshot(
        backdropStyles: Map<String, String> = mapOf(
            "domStylePosition" to "fixed",
            "domStyleBackgroundColor" to "rgba(0, 0, 0, 0.7)",
        ),
    ): Snapshot {
        val nodes = linkedMapOf(
            "app" to Node(
                ref = "app", kind = NodeKind.application, typeName = "Application",
                children = listOf("window"),
            ),
            "window" to Node(
                ref = "window", parentRef = "app", kind = NodeKind.window, typeName = "DecorView",
                role = "window", frame = Rect(0.0, 0.0, 1080.0, 2400.0), children = listOf("webView"),
            ),
            "webView" to Node(
                ref = "webView", parentRef = "window", kind = NodeKind.view, typeName = "android.webkit.WebView",
                role = "webView", frame = Rect(0.0, 0.0, 1080.0, 2400.0), isInteractive = true,
                children = listOf("body"),
            ),
            "body" to dom("body", "webView", "body", Rect(0.0, 0.0, 1080.0, 2400.0), listOf("form", "backdrop", "sheet")),
            "form" to dom("form", "body", "div", Rect(0.0, 200.0, 1080.0, 800.0), listOf("income")),
            "income" to dom(
                "income", "form", "textField", Rect(100.0, 400.0, 880.0, 60.0),
                interactive = true, text = "8000",
            ),
            "backdrop" to dom("backdrop", "body", "div", Rect(0.0, 0.0, 1080.0, 2400.0), styles = backdropStyles),
            "sheet" to dom(
                "sheet", "body", "div", Rect(0.0, 1400.0, 1080.0, 1000.0), listOf("option"),
                styles = mapOf("domStylePosition" to "fixed", "domStyleBackgroundColor" to "rgb(255, 255, 255)"),
            ),
            "option" to dom(
                "option", "sheet", "button", Rect(100.0, 1500.0, 880.0, 120.0),
                interactive = true, text = "6",
            ),
        )
        return Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0),
            rootRef = "app",
            nodes = nodes,
        )
    }

    @Test
    fun compact_marksAFieldUnderAnInPageBackdrop() {
        val income = CompactObservation.from(sheetOpenSnapshot()).items.first { it.ref == "income" }
        assertEquals(
            "backdrop",
            income.occludedBy,
            "a field under an open in-page sheet must name the backdrop: ${income.line()}",
        )
        assertTrue(income.line().contains("occluded-by:backdrop"), income.line())
    }

    @Test
    fun compact_leavesTheSheetsOwnContentReachable() {
        // The option the caller now has to tap is IN the top layer; marking it
        // occluded would make the marker useless exactly where it matters.
        val option = CompactObservation.from(sheetOpenSnapshot()).items.first { it.ref == "option" }
        assertNull(option.occludedBy, option.line())
    }

    @Test
    fun compact_ignoresABackdropThePageOptedOutOfHitTesting() {
        // `pointer-events: none` is the page stating the click goes THROUGH — the
        // one signal that can be trusted here, and the one that must be honoured.
        val snapshot = sheetOpenSnapshot(
            backdropStyles = mapOf(
                "domStylePosition" to "fixed",
                "domStyleBackgroundColor" to "rgba(0, 0, 0, 0.7)",
                "domStylePointerEvents" to "none",
            ),
        )
        val income = CompactObservation.from(snapshot).items.first { it.ref == "income" }
        assertNull(income.occludedBy, "a pointer-events:none layer is not a cover: ${income.line()}")
    }

    @Test
    fun compact_ignoresAFullScreenLayerThatPaintsNothing() {
        // A full-bleed positioning wrapper is scenery, not a cover. Without this the
        // marker lands on every item on the screen, which is the failure the native
        // container rule was written for.
        val snapshot = sheetOpenSnapshot(
            backdropStyles = mapOf(
                "domStylePosition" to "fixed",
                "domStyleBackgroundColor" to "rgba(0, 0, 0, 0)",
            ),
        )
        val income = CompactObservation.from(snapshot).items.first { it.ref == "income" }
        assertNull(income.occludedBy, "an unpainted full-screen layer is not a cover: ${income.line()}")
    }

    @Test
    fun tap_warnsWhenTheTouchWouldLandInTheSheet() {
        // The read path knowing and the act path not knowing is how the measured
        // failure got through: the type command's own targeting tap has to say it.
        val snapshot = sheetOpenSnapshot()
        val obstruction = ScreenCoverage.obstruction(snapshot, x = 540.0, y = 430.0, targetRef = "income")
        assertNotNull(obstruction, "a tap aimed under an open in-page sheet must be flagged")
        assertEquals(ScreenCoverage.OBSTRUCTED_BY_NODE, obstruction.reason)
        assertEquals("backdrop", obstruction.ref)
        assertTrue(
            obstruction.detail.contains("hit-testing"),
            "a DOM cover's reason is the page's own default, not interactivity: ${obstruction.detail}",
        )
    }

    @Test
    fun tap_isUnobstructedOnceTheSheetIsGone() {
        val nodes = LinkedHashMap(sheetOpenSnapshot().nodes)
        nodes["body"] = nodes["body"]!!.copy(children = listOf("form"))
        val snapshot = sheetOpenSnapshot().copy(nodes = nodes)
        assertNull(ScreenCoverage.obstruction(snapshot, x = 540.0, y = 430.0, targetRef = "income"))
    }

    @Test
    fun compact_stillIgnoresANonInteractiveNativeCover() {
        // The native default is unchanged: a touch falls through a view that does not
        // consume it, so a decorative frame must not be reported as cover.
        val base = sheetOpenSnapshot()
        val nodes = LinkedHashMap(base.nodes)
        nodes["window"] = nodes["window"]!!.copy(children = listOf("webView", "decor"))
        nodes["decor"] = Node(
            ref = "decor", parentRef = "window", kind = NodeKind.view, typeName = "android.widget.FrameLayout",
            role = "container", frame = Rect(0.0, 0.0, 1080.0, 2400.0), isInteractive = false,
        )
        val income = CompactObservation.from(base.copy(nodes = nodes)).items.first { it.ref == "income" }
        assertEquals("backdrop", income.occludedBy, income.line())
    }
}
