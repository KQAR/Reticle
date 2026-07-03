package dev.reticle.cli

import dev.reticle.core.MetadataValue
import dev.reticle.core.Node
import dev.reticle.core.NodeKind
import dev.reticle.core.Rect
import dev.reticle.core.ScreenInfo
import dev.reticle.core.Selector
import dev.reticle.core.Size
import dev.reticle.core.Snapshot
import kotlin.test.Test
import kotlin.test.assertContains

class SelectorDiagnosticsTest {
    @Test
    fun pointMissListsAvailableTestIds() {
        val snapshot = sampleSnapshot()

        val message = SelectorDiagnostics.pointMiss(snapshot, Selector(testId = "checkout.missing"))

        assertContains(message, "could not resolve selector 'testId=checkout.missing'")
        assertContains(message, "testId candidates")
        assertContains(message, "'checkout.payButton'")
    }

    @Test
    fun nodeMissListsAvailableCssSelectors() {
        val snapshot = sampleSnapshot()

        val message = SelectorDiagnostics.nodeMiss(snapshot, Selector(cssSelector = "#missing"))

        assertContains(message, "no matching node for selector 'css=#missing'")
        assertContains(message, "css candidates")
        assertContains(message, "'#web-pay'")
    }

    private fun sampleSnapshot(): Snapshot = Snapshot(
        capturedAtMillis = 0L,
        screen = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0),
        rootRef = "app",
        nodes = linkedMapOf(
            "app" to Node(
                ref = "app",
                kind = NodeKind.application,
                typeName = "Application",
                children = listOf("button", "dom"),
            ),
            "button" to Node(
                ref = "button",
                parentRef = "app",
                kind = NodeKind.view,
                typeName = "android.widget.Button",
                role = "button",
                testId = "checkout.payButton",
                frame = Rect(10.0, 20.0, 100.0, 40.0),
                isInteractive = true,
            ),
            "dom" to Node(
                ref = "dom",
                parentRef = "app",
                kind = NodeKind.domNode,
                typeName = "DOMElement",
                role = "button",
                text = "Pay",
                frame = Rect(100.0, 200.0, 80.0, 40.0),
                isInteractive = true,
                custom = mapOf("domCssSelector" to MetadataValue.Text("#web-pay")),
            ),
        ),
    )
}
