package dev.reticle.core

import dev.reticle.core.trace.ActionTraceDiff
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** Unit tests for the pure snapshot diff used by action trace manifests. */
class ActionTraceDiffTest {

    @Test
    fun compare_reportsChangedFieldsAndAddedNodes() {
        val before = snapshot(
            "button" to Node(
                ref = "button",
                parentRef = "root",
                kind = NodeKind.view,
                typeName = "android.widget.Button",
                text = "Pay",
                frame = Rect(0.0, 0.0, 100.0, 50.0),
                isInteractive = true,
            )
        )
        val after = snapshot(
            "button" to Node(
                ref = "button",
                parentRef = "root",
                kind = NodeKind.view,
                typeName = "android.widget.Button",
                text = "Paid",
                frame = Rect(0.0, 0.0, 100.0, 50.0),
                isInteractive = true,
            ),
            "status" to Node(
                ref = "status",
                parentRef = "root",
                kind = NodeKind.view,
                typeName = "android.widget.TextView",
                text = "Complete",
            ),
        )

        val changes = ActionTraceDiff.compare(before, after)

        assertTrue(changes.any { it.ref == "button" && it.field == "text" && it.before == "Pay" && it.after == "Paid" })
        assertTrue(changes.any { it.ref == "status" && it.field == "present" && it.before == "false" && it.after == "true" })
        assertTrue(changes.any { it.ref == null && it.field == "nodeCount" && it.before == "2" && it.after == "3" })
    }

    @Test
    fun compare_reportsCustomMetadataChanges() {
        val before = snapshot(
            "label" to Node(
                ref = "label",
                parentRef = "root",
                kind = NodeKind.view,
                typeName = "android.widget.TextView",
                custom = mapOf("alpha" to MetadataValue.Real(1.0)),
            )
        )
        val after = snapshot(
            "label" to Node(
                ref = "label",
                parentRef = "root",
                kind = NodeKind.view,
                typeName = "android.widget.TextView",
                custom = mapOf("alpha" to MetadataValue.Real(0.5)),
            )
        )

        val change = ActionTraceDiff.compare(before, after).single { it.field == "custom.alpha" }

        assertEquals("1.0", change.before)
        assertEquals("0.5", change.after)
    }

    private fun snapshot(vararg nodes: Pair<String, Node>): Snapshot {
        val children = nodes.map { it.first }
        return Snapshot(
            capturedAtMillis = 1L,
            screen = ScreenInfo(Size(100.0, 100.0), density = 1.0),
            rootRef = "root",
            nodes = linkedMapOf(
                "root" to Node(
                    ref = "root",
                    kind = NodeKind.application,
                    typeName = "android.app.Application",
                    children = children,
                ),
                *nodes,
            ),
        )
    }
}
