package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * `ui style` with a selector reports THAT node's subtree.
 *
 * The measured defect: the flag was parsed, passed through the host, and dropped at
 * the render, so `--ref r397` returned the same 2978 lines as no selector at all —
 * byte for byte, with the asked-for node on line 2912. A silently ignored selector
 * is worse than an unsupported one, because the answer looks like an answer.
 */
class StyleScopeTest {

    private fun node(ref: String, parent: String?, children: List<String>, y: Double) = Node(
        ref = ref, parentRef = parent, kind = NodeKind.view, typeName = "android.view.View",
        role = "view", resourceId = ref, frame = Rect(0.0, y, 100.0, 40.0),
        children = children,
        custom = mapOf("paddingLeft" to MetadataValue.Real(24.0)),
        styleChannels = mapOf("paddingLeft" to StyleChannel.viewField),
    )

    private fun snapshot() = Snapshot(
        capturedAtMillis = 0L,
        screen = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0),
        rootRef = "root",
        nodes = mapOf(
            "root" to node("root", null, listOf("left", "right"), 0.0),
            "left" to node("left", "root", listOf("leftChild"), 100.0),
            "leftChild" to node("leftChild", "left", emptyList(), 140.0),
            "right" to node("right", "root", emptyList(), 300.0),
        ),
    )

    @Test
    fun aScopedReportHoldsThatSubtreeAndNothingElse() {
        val scoped = Render.style(snapshot(), startRef = "left")
        assertTrue(scoped.contains("@left"), scoped)
        assertTrue(scoped.contains("@leftChild"), scoped)
        assertFalse(scoped.contains("@right"), scoped)
        assertFalse(scoped.contains("@root"), scoped)
    }

    @Test
    fun noSelectorStillReportsTheWholeScreen() {
        val whole = Render.style(snapshot())
        for (ref in listOf("@root", "@left", "@leftChild", "@right")) {
            assertTrue(whole.contains(ref), "$ref missing from the unscoped report")
        }
    }

    @Test
    fun scopingIsWhatChangesTheAnswer() {
        // The regression this pins: the two used to be identical.
        assertFalse(Render.style(snapshot(), startRef = "left") == Render.style(snapshot()))
    }

    @Test
    fun aLeafScopesToItself() {
        val scoped = Render.style(snapshot(), startRef = "right")
        assertEquals(1, scoped.lines().count { it.startsWith("@") }, scoped)
    }
}
