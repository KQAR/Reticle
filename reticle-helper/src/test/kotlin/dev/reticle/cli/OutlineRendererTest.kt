package dev.reticle.cli

import dev.reticle.core.Node
import dev.reticle.core.NodeKind
import dev.reticle.core.Rect
import dev.reticle.core.ScreenInfo
import dev.reticle.core.Size
import dev.reticle.core.Snapshot
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

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
    fun groupsAStackedScreenByWindow_topmostFirst() {
        // A form pushed over a still-live host page. Flattened by geometry alone the
        // two interleave, and the fields being driven end up scattered among nodes
        // the caller will never act on.
        val (text, entries) = OutlineRenderer.render(stackedSnapshot())

        val lines = text.lines()
        val headers = lines.filter { it.startsWith("window ") }
        assertEquals(2, headers.size, text)
        assertContains(headers[0], "[top]")
        assertContains(headers[1], "[behind the top window]")
        // Numbering starts in the window the user is looking at, rather than being
        // dominated by the background screen.
        assertEquals(listOf("form.a", "form.b", "host.a", "host.b"), entries.map { it.ref })
        assertEquals("@1", entries.first { it.ref == "form.a" }.alias)
        assertEquals("w2", entries.first { it.ref == "form.a" }.windowRef)
        // Item lines keep their exact shape: a header is a line a consumer can skip,
        // but indenting the items would break every `grep '^@N'` / `grep '^#id'`
        // written against this output — and a stacked screen is the common case, so
        // that would break them most of the time. (It broke this repo's own e2e on
        // the first live run.)
        assertTrue(
            lines.any { it.startsWith("@1 #firstName ") },
            "grouped item lines must not be indented: $text",
        )
    }

    @Test
    fun aSingleWindowOutlineHasNoHeaders() {
        // Headers on an unstacked screen would be pure noise; the output stays as
        // it was.
        val (text, _) = OutlineRenderer.render(sampleSnapshot())
        assertEquals(emptyList(), text.lines().filter { it.startsWith("window ") })
    }

    /** Two live windows, whose nodes interleave when sorted by geometry alone. */
    private fun stackedSnapshot(): Snapshot {
        fun content(ref: String, window: String, y: Double, id: String) = Node(
            ref = ref, parentRef = window, kind = NodeKind.view,
            typeName = "android.widget.TextView", role = "text",
            testId = id, text = id, frame = Rect(0.0, y, 1000.0, 100.0), isInteractive = true,
        )
        return Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(size = Size(1000.0, 2000.0), density = 3.0),
            rootRef = "app",
            nodes = linkedMapOf(
                "app" to Node(ref = "app", kind = NodeKind.application, typeName = "Application", children = listOf("w1", "w2")),
                "w1" to Node(
                    ref = "w1", parentRef = "app", kind = NodeKind.window, typeName = "DecorView",
                    frame = Rect(0.0, 0.0, 1000.0, 2000.0), children = listOf("host.a", "host.b"),
                ),
                "w2" to Node(
                    ref = "w2", parentRef = "app", kind = NodeKind.window, typeName = "DecorView",
                    frame = Rect(0.0, 0.0, 1000.0, 2000.0), children = listOf("form.a", "form.b"),
                ),
                "host.a" to content("host.a", "w1", 150.0, "loanCard"),
                "form.a" to content("form.a", "w2", 100.0, "firstName"),
                "host.b" to content("host.b", "w1", 400.0, "ivBg"),
                "form.b" to content("form.b", "w2", 300.0, "lastName"),
            ),
        )
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
    fun corruptAliasCacheThrowsCleanError() {
        val home = Files.createTempDirectory("reticle-alias-home").toFile()
        val oldHome = System.getProperty("user.home")
        System.setProperty("user.home", home.absolutePath)
        try {
            val dir = File(File(File(home, ".reticle"), "aliases"), "emulator-5554/dev.reticle.sample")
            dir.mkdirs()
            val cache = File(dir, "last-outline.json")

            // A truncated write (non-JSON) surfaces a clean error, not a parse crash.
            cache.writeText("{ this is not valid json")
            val e1 = assertFailsWith<CliError> {
                OutlineRenderer.resolveAlias("emulator-5554", "dev.reticle.sample", "@1")
            }
            assertContains(e1.message ?: "", "corrupt")

            // Valid JSON at the right version but a malformed entry (missing frame).
            cache.writeText("""{"version":1,"entries":[{"alias":"@1","ref":"r","role":"button"}]}""")
            val e2 = assertFailsWith<CliError> {
                OutlineRenderer.resolveAlias("emulator-5554", "dev.reticle.sample", "@1")
            }
            assertContains(e2.message ?: "", "corrupt")
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
