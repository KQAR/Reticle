package dev.reticle.core

import kotlinx.serialization.Serializable

/**
 * Compact observation.
 *
 * The full snapshot stays on disk; agents receive a compact, token-cheap
 * summary by default and then query/inspect specific refs on demand. Each line
 * is one interactive or labelled node with just enough to act on it.
 */
@Serializable
data class CompactObservation(
    val capturedAtMillis: Long,
    val screen: ScreenInfo,
    val items: List<CompactItem>,
) {
    companion object {
        /** Build from a snapshot, keeping interactive or labelled nodes. */
        fun from(snapshot: Snapshot, maxItems: Int = 200): CompactObservation {
            val items = ArrayList<CompactItem>()
            fun visit(ref: String) {
                val node = snapshot.nodes[ref] ?: return
                val labelled = node.testId != null ||
                    node.resourceId != null ||
                    node.contentDescription != null ||
                    !node.text.isNullOrBlank()
                if ((node.isInteractive || labelled) && node.isVisible) {
                    items.add(
                        CompactItem(
                            ref = node.ref,
                            role = node.role ?: node.typeName,
                            testId = node.testId,
                            resourceId = node.resourceId,
                            label = node.contentDescription ?: node.text,
                            frame = node.frame,
                            isEnabled = node.isEnabled,
                            isInteractive = node.isInteractive,
                        )
                    )
                }
                node.children.forEach(::visit)
            }
            visit(snapshot.rootRef)
            return CompactObservation(
                capturedAtMillis = snapshot.capturedAtMillis,
                screen = snapshot.screen,
                items = items.take(maxItems),
            )
        }
    }
}

@Serializable
data class CompactItem(
    val ref: String,
    val role: String,
    val testId: String? = null,
    val resourceId: String? = null,
    val label: String? = null,
    val frame: Rect? = null,
    val isEnabled: Boolean = true,
    val isInteractive: Boolean = false,
) {
    /** One-line rendering for agent-facing text output. */
    fun line(): String {
        val selector = testId?.let { "#$it" }
            ?: resourceId?.let { "@$it" }
            ?: ref
        val labelPart = label?.let { " \"${it.take(40)}\"" } ?: ""
        val framePart = frame?.let {
            " [${it.x.toInt()},${it.y.toInt()} ${it.width.toInt()}x${it.height.toInt()}]"
        } ?: ""
        val state = buildString {
            if (!isEnabled) append(" disabled")
            if (isInteractive) append(" tappable")
        }
        return "$selector $role$labelPart$framePart$state"
    }
}
