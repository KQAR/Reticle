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
 *        ├─ button   "Pay"  testId=pay       interactive
 *        ├─ label    "Total: 9"              (text only, not interactive)
 *        └─ WebView
 *            └─ DOM button "Pay in WebView"  testId=web.payButton interactive
 */
class SnapshotDerivationsTest {

    private fun sampleSnapshot(): Snapshot {
        val nodes = linkedMapOf(
            "app" to Node(ref = "app", kind = NodeKind.application, typeName = "Application", children = listOf("box")),
            "box" to Node(
                ref = "box", parentRef = "app", kind = NodeKind.view, typeName = "FrameLayout",
                role = "container", children = listOf("pay", "label", "web"),
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
            "web" to Node(
                ref = "web", parentRef = "box", kind = NodeKind.view, typeName = "android.webkit.WebView",
                role = "container", children = listOf("webPay"),
            ),
            "webPay" to Node(
                ref = "webPay", parentRef = "web", kind = NodeKind.domNode, typeName = "DOMElement",
                role = "button", text = "Pay in WebView", testId = "web.payButton", isInteractive = true,
                frame = Rect(0.0, 140.0, 240.0, 72.0),
                custom = mapOf("domCssSelector" to MetadataValue.Text("#web-pay")),
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
        assertTrue("webPay" in refs, "interactive DOM button must be kept")
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

    /**
     * Two stacked windows (base activity + dialog on top) plus a visible IME:
     *
     *   app
     *    ├─ baseWindow                       (full screen)
     *    │   ├─ login   "Log in"  y=2100     -> under the keyboard
     *    │   └─ profile "Profile" y=600      -> under the dialog
     *    └─ dialogWindow          y=400..1000 (stacked above baseWindow)
     *        └─ confirm "Confirm" y=700      -> topmost, unobstructed
     */
    private fun occlusionSnapshot(): Snapshot {
        val nodes = linkedMapOf(
            "app" to Node(
                ref = "app", kind = NodeKind.application, typeName = "Application",
                children = listOf("baseWindow", "dialogWindow"),
            ),
            "baseWindow" to Node(
                ref = "baseWindow", parentRef = "app", kind = NodeKind.window, typeName = "DecorView",
                role = "window", frame = Rect(0.0, 0.0, 1080.0, 2400.0), children = listOf("login", "profile"),
            ),
            "login" to Node(
                ref = "login", parentRef = "baseWindow", kind = NodeKind.view, typeName = "android.widget.Button",
                role = "button", text = "Log in", testId = "login", isInteractive = true,
                frame = Rect(100.0, 2100.0, 880.0, 120.0),
            ),
            "profile" to Node(
                ref = "profile", parentRef = "baseWindow", kind = NodeKind.view, typeName = "android.widget.Button",
                role = "button", text = "Profile", testId = "profile", isInteractive = true,
                frame = Rect(100.0, 600.0, 880.0, 120.0),
            ),
            "dialogWindow" to Node(
                ref = "dialogWindow", parentRef = "app", kind = NodeKind.window, typeName = "DecorView",
                role = "window", frame = Rect(50.0, 400.0, 980.0, 600.0), children = listOf("confirm"),
            ),
            "confirm" to Node(
                ref = "confirm", parentRef = "dialogWindow", kind = NodeKind.view, typeName = "android.widget.Button",
                role = "button", text = "Confirm", testId = "confirm", isInteractive = true,
                frame = Rect(100.0, 700.0, 880.0, 120.0),
            ),
        )
        return Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(
                size = Size(1080.0, 2400.0),
                density = 3.0,
                keyboard = KeyboardInfo(visible = true, frame = Rect(0.0, 2000.0, 1080.0, 400.0)),
            ),
            rootRef = "app",
            nodes = nodes,
        )
    }

    @Test
    fun compact_marksItemsUnderTheKeyboard() {
        val compact = CompactObservation.from(occlusionSnapshot())
        val login = compact.items.first { it.ref == "login" }
        assertEquals(CompactObservation.OCCLUDER_KEYBOARD, login.occludedBy)
        assertTrue(login.line().contains("occluded-by:keyboard"), login.line())
    }

    @Test
    fun compact_marksItemsUnderAHigherWindow() {
        val compact = CompactObservation.from(occlusionSnapshot())
        val profile = compact.items.first { it.ref == "profile" }
        assertEquals("dialogWindow", profile.occludedBy, "background-page item under the dialog must name the covering window")
        assertTrue(profile.line().contains("occluded-by:dialogWindow"), profile.line())
    }

    @Test
    fun compact_topmostWindowItemsAreNotOccluded() {
        val compact = CompactObservation.from(occlusionSnapshot())
        assertNull(compact.items.first { it.ref == "confirm" }.occludedBy)
        // Keyboard hidden -> nothing is occluded anywhere.
        val noKeyboard = occlusionSnapshot().let {
            it.copy(screen = it.screen.copy(keyboard = KeyboardInfo(visible = false)))
        }
        val items = CompactObservation.from(noKeyboard).items
        assertNull(items.first { it.ref == "login" }.occludedBy)
    }

    @Test
    fun semanticTree_keepsSignalNodes_findBySelectors() {
        val tree = SemanticTree.build(sampleSnapshot())
        // button is interactive + has text + testId -> kept and findable
        val pay = assertNotNull(tree.findByTestId("pay"))
        assertEquals("Pay", pay.label)
        // label has text -> kept
        assertNotNull(tree.nodes.values.firstOrNull { it.label == "Total: 9" })
        // DOM nodes are already part of the same snapshot, so no special tree is needed.
        assertNotNull(tree.findByTestId("web.payButton"))
        // bare container carries no targeting signal -> dropped
        assertNull(tree.nodes["box"])
    }

    @Test
    fun semanticTree_rootAndChildRefsAlwaysResolve() {
        val tree = SemanticTree.build(sampleSnapshot())
        // The synthesized root resolves (the app root was dropped, so this is the
        // regression guard: rootRef must point at a node that exists).
        assertNotNull(tree.node(tree.rootRef), "rootRef must resolve to a node")
        assertNotNull(tree.root(), "root() must resolve")

        // Every child ref referenced by any node must exist in the node set, and
        // every non-root node's parentRef must too — no dangling refs.
        for (node in tree.nodes.values) {
            for (childRef in node.children) {
                assertNotNull(tree.node(childRef), "child ref $childRef must resolve")
            }
            node.parentRef?.let { parentRef ->
                assertNotNull(tree.node(parentRef), "parent ref $parentRef must resolve")
            }
        }

        // The whole kept set is reachable by walking children from the root.
        val reachable = HashSet<String>()
        fun walk(ref: String) {
            if (!reachable.add(ref)) return
            tree.node(ref)?.children?.forEach(::walk)
        }
        walk(tree.rootRef)
        assertTrue("pay" in reachable, "pay must be reachable from root")
        assertTrue("webPay" in reachable, "webPay must be reachable from root")
        assertEquals(tree.nodes.keys, reachable, "every kept node must be reachable from root")
    }

    @Test
    fun semanticTree_liftsChildrenAcrossDroppedContainer() {
        // 'box' (bare container) is dropped, so 'pay'/'label'/'web' must be
        // reparented onto the synthesized root rather than the dropped 'box'.
        val tree = SemanticTree.build(sampleSnapshot())
        val pay = assertNotNull(tree.findByTestId("pay"))
        assertNotNull(tree.node(pay.parentRef!!), "pay's parent must resolve, not point at dropped 'box'")
        assertEquals(tree.rootRef, pay.parentRef, "pay lifts to the root since 'box' was dropped")
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
