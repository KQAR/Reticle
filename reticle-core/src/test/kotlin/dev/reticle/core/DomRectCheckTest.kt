package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * A DOM rect folded outside the view that draws it — the one case of a wrong
 * page-to-device fold that can be STATED rather than guessed at.
 *
 * Mirrored by `DomRectCheckTests` (Swift). Hand-written on both sides rather than
 * driven from a fixture because the rule is a single containment test with no
 * decision table to pin; what has to match across the ports is the verdict, and
 * these two files assert the same three.
 */
class DomRectCheckTest {

    @Test
    fun aRectInsideItsHostIsNotSuspect() {
        assertNull(DomRectCheck.outsideHost(tree(domY = 400.0), "dom"))
    }

    @Test
    fun aRectFoldedAboveItsHostIsSuspectAndNamesTheHost() {
        // The shape measured on a real page: rects offset from what was on screen, so
        // the fold put the element outside the web view that renders it. A tap at the
        // reported centre cannot land on it, and the tap reported `settled=1`.
        val complaint = DomRectCheck.outsideHost(tree(domY = 20.0), "dom")
        assertTrue(complaint != null, "a rect above its host must be reported")
        assertTrue(complaint!!.contains("checkout.webView"), "the host must be named: $complaint")
        assertTrue(complaint.contains("act activate --css"), "a next step must be named: $complaint")
    }

    @Test
    fun onlyTheStrongCaseFires() {
        // A partially-visible element legitimately hangs over its host's edge — an
        // in-page scroll container mid-scroll does exactly this — so overlap alone
        // proves nothing and a warning on it would fire on ordinary screens.
        assertNull(DomRectCheck.outsideHost(tree(domY = 180.0), "dom"))
        // And a native node is never judged: there is no fold to be wrong.
        assertNull(DomRectCheck.outsideHost(tree(domY = 400.0), "web"))
    }

    /** A web view at y=200..2200 with one DOM node whose top is [domY]. */
    private fun tree(domY: Double): Snapshot {
        val nodes = linkedMapOf(
            "app" to Node(ref = "app", kind = NodeKind.application, typeName = "Application", children = listOf("web")),
            "web" to Node(
                ref = "web", parentRef = "app", kind = NodeKind.view,
                typeName = "android.webkit.WebView", role = "container", testId = "checkout.webView",
                frame = Rect(0.0, 200.0, 1080.0, 2000.0), isInteractive = true, children = listOf("dom"),
            ),
            "dom" to Node(
                ref = "dom", parentRef = "web", kind = NodeKind.domNode,
                typeName = "DOMElement", role = "button", text = "Continue",
                frame = Rect(100.0, domY, 800.0, 100.0), isInteractive = true,
            ),
        )
        return Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0),
            rootRef = "app",
            nodes = nodes,
        )
    }
}
