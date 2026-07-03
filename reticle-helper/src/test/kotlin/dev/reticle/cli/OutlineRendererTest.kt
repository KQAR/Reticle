package dev.reticle.cli

import dev.reticle.core.Node
import dev.reticle.core.NodeKind
import dev.reticle.core.Rect
import dev.reticle.core.ScreenInfo
import dev.reticle.core.Size
import dev.reticle.core.Snapshot
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

class OutlineRendererTest {
    @Test
    fun rendersAgentFacingAliasesInScreenOrder() {
        val (text, entries) = OutlineRenderer.render(sampleSnapshot())

        assertContains(text, "Screen: 1080x2400")
        assertContains(text, "@1 #checkout.status text \"Cart\" [20,100 200x40]")
        assertContains(text, "@2 #checkout.payButton button \"Pay\" [10,200 100x40] tappable")
        assertEquals(listOf("@1", "@2"), entries.map { it.alias })
    }

    @Test
    fun writesAndResolvesAliasCache() {
        val home = Files.createTempDirectory("reticle-alias-home").toFile()
        val oldHome = System.getProperty("user.home")
        System.setProperty("user.home", home.absolutePath)
        try {
            val snapshot = sampleSnapshot()
            val (_, entries) = OutlineRenderer.render(snapshot)
            OutlineRenderer.writeCache(snapshot, entries, serial = "emulator-5554", packageName = "dev.reticle.sample")

            val resolved = OutlineRenderer.resolveAlias("emulator-5554", "dev.reticle.sample", "@2")

            assertNotNull(resolved)
            assertEquals("button", resolved.role)
            assertEquals(60.0, resolved.frame.centerX)
            assertEquals(220.0, resolved.frame.centerY)
        } finally {
            System.setProperty("user.home", oldHome)
            home.deleteRecursively()
        }
    }

    @Test
    fun marksRepeatedVerticalItemsWithOrdinals() {
        val (text, entries) = OutlineRenderer.render(listSnapshot())

        assertContains(text, "@1 #row.one button \"One\" [20,100 300x48] tappable item 1/3")
        assertContains(text, "@2 #row.two button \"Two\" [20,160 300x48] tappable item 2/3")
        assertContains(text, "@3 #row.three button \"Three\" [20,220 300x48] tappable item 3/3")
        assertEquals(listOf(1, 2, 3), entries.map { it.listIndex })
        assertEquals(listOf(3, 3, 3), entries.map { it.listSize })
    }

    private fun sampleSnapshot(): Snapshot = Snapshot(
        capturedAtMillis = 123L,
        screen = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0),
        rootRef = "app",
        nodes = linkedMapOf(
            "app" to Node(
                ref = "app",
                kind = NodeKind.application,
                typeName = "Application",
                children = listOf("button", "status"),
            ),
            "button" to Node(
                ref = "button",
                parentRef = "app",
                kind = NodeKind.view,
                typeName = "android.widget.Button",
                role = "button",
                testId = "checkout.payButton",
                text = "Pay",
                frame = Rect(10.0, 200.0, 100.0, 40.0),
                isInteractive = true,
            ),
            "status" to Node(
                ref = "status",
                parentRef = "app",
                kind = NodeKind.view,
                typeName = "android.widget.TextView",
                role = "text",
                testId = "checkout.status",
                text = "Cart",
                frame = Rect(20.0, 100.0, 200.0, 40.0),
                isInteractive = false,
            ),
        ),
    )

    private fun listSnapshot(): Snapshot = Snapshot(
        capturedAtMillis = 456L,
        screen = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0),
        rootRef = "app",
        nodes = linkedMapOf(
            "app" to Node(
                ref = "app",
                kind = NodeKind.application,
                typeName = "Application",
                children = listOf("one", "two", "three"),
            ),
            "one" to row("one", "row.one", "One", 100.0),
            "two" to row("two", "row.two", "Two", 160.0),
            "three" to row("three", "row.three", "Three", 220.0),
        ),
    )

    private fun row(ref: String, testId: String, text: String, y: Double): Node = Node(
        ref = ref,
        parentRef = "app",
        kind = NodeKind.view,
        typeName = "android.widget.Button",
        role = "button",
        testId = testId,
        text = text,
        frame = Rect(20.0, y, 300.0, 48.0),
        isInteractive = true,
    )
}
