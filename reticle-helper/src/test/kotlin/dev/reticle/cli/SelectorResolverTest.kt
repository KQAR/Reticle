package dev.reticle.cli

import dev.reticle.core.MetadataValue
import dev.reticle.core.Node
import dev.reticle.core.NodeKind
import dev.reticle.core.Rect
import dev.reticle.core.ScreenInfo
import dev.reticle.core.Selector
import dev.reticle.core.SemanticTree
import dev.reticle.core.Size
import dev.reticle.core.Snapshot
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull

class SelectorResolverTest {
    @Test
    fun resolvesDomNodeByCssSelector() {
        val snapshot = Snapshot(
            capturedAtMillis = 0L,
            screen = ScreenInfo(size = Size(1080.0, 2400.0), density = 3.0),
            rootRef = "app",
            nodes = linkedMapOf(
                "app" to Node(
                    ref = "app",
                    kind = NodeKind.application,
                    typeName = "Application",
                    children = listOf("web"),
                ),
                "web" to Node(
                    ref = "web",
                    parentRef = "app",
                    kind = NodeKind.view,
                    typeName = "android.webkit.WebView",
                    children = listOf("dom"),
                ),
                "dom" to Node(
                    ref = "dom",
                    parentRef = "web",
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

        val resolved = SelectorResolver(snapshot, SemanticTree.build(snapshot))
            .resolve(Selector(cssSelector = "#web-pay"))

        assertNotNull(resolved)
        assertEquals("dom:css", resolved.source)
        assertEquals("dom", resolved.ref)
        assertEquals(140.0, resolved.point.x)
        assertEquals(220.0, resolved.point.y)
    }
}
