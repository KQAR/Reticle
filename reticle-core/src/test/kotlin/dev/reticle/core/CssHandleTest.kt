package dev.reticle.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * What a DOM node's handle costs to PRINT, which is a different question from what
 * the traversal has to capture.
 *
 * Measured on a real hybrid form: every `ui outline` line carried the element's
 * full ancestor path (~400 characters), and one screen cost 17.8 KB against 5.9 KB
 * for the same screen's `ui compact` — the view sold as the cheap ad-hoc loop was
 * the most expensive one to read.
 *
 * The rule under test: shorten to the point of uniqueness, never past it. A handle
 * that resolves to a DIFFERENT node than the one it labels would be worse than the
 * 400 characters, so the last case here re-resolves every handle through the
 * matcher that will actually be given it.
 */
class CssHandleTest {
    /** A real Vue form's shape: N rows, each `div.form-row > div.body > input`. */
    private class Page(rowCount: Int, val positional: Boolean = true, val ids: Boolean = false) {
        val nodes = LinkedHashMap<String, Node>()
        private fun add(
            ref: String,
            parentRef: String,
            tag: String,
            classes: String?,
            path: String,
            nth: Int,
            role: String,
            id: String? = null,
        ) {
            nodes[ref] = Node(
                ref = ref,
                parentRef = parentRef,
                kind = NodeKind.domNode,
                typeName = "DOMElement",
                role = role,
                frame = Rect(0.0, 0.0, 100.0, 20.0),
                isInteractive = role == "textField",
                custom = buildMap {
                    put("domTag", MetadataValue.Text(tag))
                    classes?.let { put("domClass", MetadataValue.Text(it)) }
                    put("domCssSelector", MetadataValue.Text(path))
                    id?.let { put("domId", MetadataValue.Text(it)) }
                    if (positional) {
                        put("domNthOfType", MetadataValue.Integer(nth.toLong()))
                        put("domNthChild", MetadataValue.Integer(nth.toLong()))
                    }
                },
            )
        }

        val inputRefs: List<String>

        init {
            nodes["app"] = Node(
                ref = "app", kind = NodeKind.application, typeName = "Application",
                children = listOf("web"),
            )
            nodes["web"] = Node(
                ref = "web", parentRef = "app", kind = NodeKind.view,
                typeName = "android.webkit.WebView", role = "webView",
                frame = Rect(0.0, 0.0, 1080.0, 2400.0), isInteractive = true,
                children = listOf("body"),
            )
            val bodyPath = "body:nth-of-type(1)"
            add("body", "web", "body", null, bodyPath, 1, "body")
            val inputs = ArrayList<String>()
            val rows = ArrayList<String>()
            for (i in 1..rowCount) {
                val rowPath = "$bodyPath > div.form-row:nth-of-type($i)"
                val bodyRowPath = "$rowPath > div.ep-form-field__body:nth-of-type(1)"
                val inputPath = "$bodyRowPath > input.ep-form-base-input__control:nth-of-type(1)"
                add("row$i", "body", "div", "form-row", rowPath, i, "div")
                add("body$i", "row$i", "div", "ep-form-field__body", bodyRowPath, 1, "div")
                add(
                    "input$i", "body$i", "input", "ep-form-base-input__control", inputPath, 1, "textField",
                    id = if (ids) "amount" else null,
                )
                nodes["row$i"] = nodes["row$i"]!!.copy(children = listOf("body$i"))
                nodes["body$i"] = nodes["body$i"]!!.copy(children = listOf("input$i"))
                rows += "row$i"
                inputs += "input$i"
            }
            nodes["body"] = nodes["body"]!!.copy(children = rows)
            inputRefs = inputs
        }

        fun snapshot(): Snapshot = Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0),
            rootRef = "app",
            nodes = nodes,
        )

        fun input(i: Int): Node = nodes["input$i"]!!
    }

    @Test
    fun anIdWinsOverEveryPath() {
        val page = Page(rowCount = 1, ids = true)
        assertEquals("#amount", CssHandle.of(page.snapshot(), page.input(1)))
    }

    @Test
    fun aRepeatedIdIsNotAHandle() {
        // Two elements with one id is invalid HTML and entirely ordinary in the wild.
        // `#amount` would then name whichever the matcher reached first.
        val page = Page(rowCount = 2, ids = true)
        val handle = CssHandle.of(page.snapshot(), page.input(2))
        assertTrue(handle != "#amount", "a duplicated id must not be offered as the handle: $handle")
    }

    @Test
    fun theTailAloneIsEnoughWhenNothingElseSharesIt() {
        val page = Page(rowCount = 1)
        assertEquals(
            "input.ep-form-base-input__control:nth-of-type(1)",
            CssHandle.of(page.snapshot(), page.input(1)),
        )
    }

    @Test
    fun itGrowsUntilItNamesOneNode_andStopsThere() {
        // Three identical rows: the tail is ambiguous and the row index is what tells
        // them apart, so the handle must reach that segment and go no further.
        val page = Page(rowCount = 3)
        val handle = CssHandle.of(page.snapshot(), page.input(3))!!
        assertTrue(handle.startsWith("div.form-row:nth-of-type(3)"), handle)
        assertTrue(handle.endsWith("input.ep-form-base-input__control:nth-of-type(1)"), handle)
        val full = page.input(3).domCssSelector()!!
        assertTrue(handle.length < full.length, "handle ($handle) must be shorter than its lineage")
    }

    @Test
    fun aNativeNodeHasNoCssHandleAtAll() {
        val page = Page(rowCount = 1)
        val native = Node(
            ref = "n", parentRef = "app", kind = NodeKind.view,
            typeName = "android.widget.Button", role = "button", testId = "pay",
        )
        assertNull(CssHandle.of(page.snapshot(), native))
    }

    @Test
    fun aCaptureThatCannotAnswerAPositionKeepsItsFullPath() {
        // An agent predating `domNthOfType` cannot answer `:nth-of-type(n)`, and the
        // matcher refuses such a selector by name — while the full path still matches
        // verbatim. Shortening there would trade a handle that works for one that is
        // refused.
        val page = Page(rowCount = 3, positional = false)
        val node = page.input(3)
        assertEquals(node.domCssSelector(), CssHandle.of(page.snapshot(), node))
    }

    @Test
    fun everyShortenedHandleReResolvesToItsOwnNode() {
        // The contract that makes shortening safe at all, checked through the matcher
        // that will be handed the printed handle.
        for (rowCount in 1..4) {
            val page = Page(rowCount = rowCount)
            val snapshot = page.snapshot()
            for (i in 1..rowCount) {
                val node = page.input(i)
                val handle = CssHandle.of(snapshot, node)!!
                assertEquals(
                    node.ref,
                    CssSelectorMatch.find(snapshot, handle)?.ref,
                    "handle '$handle' re-resolved elsewhere",
                )
            }
        }
    }

    @Test
    fun oneIndexAnswersEveryNodeOfTheCapture() {
        // The projection path: a shared index, so shortening 200 handles does not walk
        // the node set 200 times. Same answers as the one-shot form.
        val page = Page(rowCount = 3)
        val snapshot = page.snapshot()
        val index = CssHandle.Index(snapshot)
        for (i in 1..3) {
            assertEquals(CssHandle.of(snapshot, page.input(i)), index.of(page.input(i)))
        }
    }
}
