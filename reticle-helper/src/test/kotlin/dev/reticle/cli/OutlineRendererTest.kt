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
}
