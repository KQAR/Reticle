package dev.reticle.cli

import dev.reticle.core.Node
import dev.reticle.core.NodeKind
import dev.reticle.core.Rect
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class AliasLiveMatchTest {
    @Test
    fun followsSelectorMatchedNodeAfterRelayout() {
        // Cached while the button sat at y=200; a relayout moved it to y=600.
        val entry = entry(testId = "login.submit", frame = Rect(10.0, 200.0, 100.0, 40.0))
        val live = listOf(
            node("r1", testId = "login.otp", frame = Rect(10.0, 100.0, 100.0, 40.0)),
            node("r2", testId = "login.submit", frame = Rect(10.0, 600.0, 100.0, 40.0)),
        )

        val matched = aliasLiveMatch(live, entry)

        assertEquals("r2", matched?.ref)
    }

    @Test
    fun prefersNearestWhenSeveralNodesShareTheSelector() {
        // Repeated list rows share a testId; the alias pointed at the middle one.
        val entry = entry(testId = "row", frame = Rect(20.0, 160.0, 300.0, 48.0))
        val live = listOf(
            node("r1", testId = "row", frame = Rect(20.0, 110.0, 300.0, 48.0)),
            node("r2", testId = "row", frame = Rect(20.0, 170.0, 300.0, 48.0)),
            node("r3", testId = "row", frame = Rect(20.0, 230.0, 300.0, 48.0)),
        )

        assertEquals("r2", aliasLiveMatch(live, entry)?.ref)
    }

    @Test
    fun fallsBackToLabelAndRoleWhenEntryHasNoSelector() {
        val entry = entry(testId = null, label = "Dalej", role = "button", frame = Rect(10.0, 200.0, 100.0, 40.0))
        val live = listOf(
            node("r1", text = "Wróć", role = "button", frame = Rect(10.0, 100.0, 100.0, 40.0)),
            node("r2", text = "Dalej", role = "button", frame = Rect(10.0, 640.0, 100.0, 40.0)),
        )

        assertEquals("r2", aliasLiveMatch(live, entry)?.ref)
    }

    @Test
    fun answersNullWhenTheNodeIsGone() {
        val entry = entry(testId = "login.submit", frame = Rect(10.0, 200.0, 100.0, 40.0))
        val live = listOf(
            node("r1", testId = "login.otp", frame = Rect(10.0, 100.0, 100.0, 40.0)),
        )

        assertNull(aliasLiveMatch(live, entry))
    }

    @Test
    fun ignoresInvisibleNodes() {
        val entry = entry(testId = "login.submit", frame = Rect(10.0, 200.0, 100.0, 40.0))
        val live = listOf(
            node("r1", testId = "login.submit", frame = Rect(10.0, 200.0, 100.0, 40.0), visible = false),
        )

        assertNull(aliasLiveMatch(live, entry))
    }

    private fun entry(
        testId: String? = null,
        label: String? = null,
        role: String = "button",
        frame: Rect,
    ): OutlineRenderer.Entry = OutlineRenderer.Entry(
        alias = "@1",
        ref = "cached",
        role = role,
        label = label,
        frame = frame,
        testId = testId,
        resourceId = null,
        css = null,
        enabled = true,
        interactive = true,
    )

    private fun node(
        ref: String,
        testId: String? = null,
        text: String? = null,
        role: String = "button",
        frame: Rect,
        visible: Boolean = true,
    ): Node = Node(
        ref = ref,
        parentRef = "app",
        kind = NodeKind.view,
        typeName = "android.widget.Button",
        role = role,
        testId = testId,
        text = text,
        frame = frame,
        isVisible = visible,
        isInteractive = true,
    )
}
