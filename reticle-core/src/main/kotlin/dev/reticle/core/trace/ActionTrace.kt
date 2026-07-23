package dev.reticle.core.trace

import dev.reticle.core.MetadataValue
import dev.reticle.core.Node
import dev.reticle.core.Point
import dev.reticle.core.Rect
import dev.reticle.core.Selector
import dev.reticle.core.Snapshot
import kotlinx.serialization.Serializable

/**
 * Evidence package manifest for one dispatched action.
 *
 * Large artifacts stay beside this manifest on disk and are referenced by
 * relative path, so the same shape can later be streamed through the daemon
 * event bus without inlining snapshots or screenshots into every event.
 */
@Serializable
data class ActionTrace(
    val traceVersion: Int = 1,
    val actionId: String,
    val packageName: String,
    /**
     * Source platform ("android" / "ios"), copied from the captured snapshot so
     * a trace manifest is self-describing across platforms — the iOS writer
     * (`IosActionTrace`) already emits this, and consumers (replay, the panel)
     * read one shape. Defaulted so older/direct callers stay wire-compatible;
     * the helper always populates it, so it is emitted in practice.
     */
    val platform: String = "",
    val recordedAtMillis: Long,
    val gesture: String,
    val selector: Selector? = null,
    val target: ActionTraceTarget? = null,
    val result: Map<String, String> = emptyMap(),
    val artifacts: ActionTraceArtifacts,
    val diff: List<ActionTraceChange> = emptyList(),
)

/** Targeting evidence for actions that resolve to a concrete screen point. */
@Serializable
data class ActionTraceTarget(
    val point: Point? = null,
    val source: String? = null,
    val ref: String? = null,
)

/** Relative artifact paths inside an action trace directory. */
@Serializable
data class ActionTraceArtifacts(
    val beforeSnapshot: String,
    val afterSnapshot: String,
    val beforeScreenshot: String? = null,
    val afterScreenshot: String? = null,
)

/** One compact before/after fact extracted from two snapshots. */
@Serializable
data class ActionTraceChange(
    val ref: String? = null,
    val field: String,
    val before: String? = null,
    val after: String? = null,
)

/** Pure snapshot diffing for action traces; intentionally compact and bounded. */
object ActionTraceDiff {
    fun compare(before: Snapshot, after: Snapshot, maxChanges: Int = 100): List<ActionTraceChange> {
        val out = ArrayList<ActionTraceChange>()
        fun add(ref: String?, field: String, old: String?, new: String?) {
            if (old == new || out.size >= maxChanges) return
            out.add(ActionTraceChange(ref = ref, field = field, before = old, after = new))
        }

        add(null, "nodeCount", before.nodes.size.toString(), after.nodes.size.toString())
        val refs = (before.nodes.keys + after.nodes.keys).sorted()
        for (ref in refs) {
            if (out.size >= maxChanges) break
            val b = before.nodes[ref]
            val a = after.nodes[ref]
            when {
                b == null && a != null -> add(ref, "present", "false", "true")
                b != null && a == null -> add(ref, "present", "true", "false")
                b != null && a != null -> compareNode(ref, b, a, ::add)
            }
        }
        if (out.size >= maxChanges) {
            out.add(ActionTraceChange(field = "truncated", before = null, after = maxChanges.toString()))
        }
        return out
    }

    private fun compareNode(
        ref: String,
        before: Node,
        after: Node,
        add: (String?, String, String?, String?) -> Unit,
    ) {
        add(ref, "kind", before.kind.name, after.kind.name)
        add(ref, "role", before.role, after.role)
        add(ref, "text", before.text, after.text)
        add(ref, "label", before.contentDescription, after.contentDescription)
        add(ref, "testId", before.testId, after.testId)
        add(ref, "resourceId", before.resourceId, after.resourceId)
        add(ref, "frame", before.frame?.traceString(), after.frame?.traceString())
        add(ref, "visible", before.isVisible.toString(), after.isVisible.toString())
        add(ref, "enabled", before.isEnabled.toString(), after.isEnabled.toString())
        add(ref, "interactive", before.isInteractive.toString(), after.isInteractive.toString())
        add(ref, "children", before.children.joinToString(","), after.children.joinToString(","))
        add(ref, "regions", before.regions.size.toString(), after.regions.size.toString())
        val customKeys = (before.custom.keys + after.custom.keys).sorted()
        for (key in customKeys) {
            add(ref, "custom.$key", before.custom[key]?.traceDisplay(), after.custom[key]?.traceDisplay())
        }
    }

    private fun Rect.traceString(): String =
        "${x.toInt()},${y.toInt()} ${width.toInt()}x${height.toInt()}"

    private fun MetadataValue.traceDisplay(): String = displayString()
}
