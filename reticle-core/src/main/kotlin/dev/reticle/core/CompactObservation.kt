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
        /** [CompactItem.occludedBy] value for the system keyboard (IME). */
        const val OCCLUDER_KEYBOARD = "keyboard"

        /** Build from a snapshot, keeping interactive or labelled nodes. */
        fun from(snapshot: Snapshot, maxItems: Int = 200): CompactObservation {
            // Occlusion is judged at the item's tap point (frame center — where
            // selector-resolved taps land) against everything stacked above it:
            // higher z-order in-app windows (application children are the
            // WindowManagerGlobal roots in stacking order, dialogs/popups last)
            // and the IME. The keyboard is another process's window — never a
            // node — so it comes from ScreenInfo.keyboard, not the tree.
            val windowRefs = snapshot.root()?.children
                ?.filter { snapshot.nodes[it]?.kind == NodeKind.window }
                ?: emptyList()
            val windowOrder = windowRefs.withIndex().associate { (i, ref) -> ref to i }
            val keyboardFrame = snapshot.screen.keyboard?.takeIf { it.visible }?.frame

            fun occluderOf(node: Node, windowRef: String?): String? {
                val frame = node.frame ?: return null
                val cx = frame.centerX
                val cy = frame.centerY
                // The IME layer sits above every app window, so it wins when
                // both it and a dialog cover the point.
                if (keyboardFrame?.contains(cx, cy) == true) return OCCLUDER_KEYBOARD
                val index = windowRef?.let { windowOrder[it] } ?: return null
                for (i in (index + 1) until windowRefs.size) {
                    val above = snapshot.nodes[windowRefs[i]] ?: continue
                    if (!above.isVisible) continue
                    if (above.frame?.contains(cx, cy) == true) return above.ref
                }
                return null
            }

            val items = ArrayList<CompactItem>()
            fun visit(ref: String, windowRef: String?) {
                val node = snapshot.nodes[ref] ?: return
                val currentWindow = if (node.kind == NodeKind.window) node.ref else windowRef
                // Same targeting-signal test as the semantic tree, plus a
                // visibility filter: the compact view is for acting *now*, so a
                // hidden-but-labelled node is intentionally omitted here even
                // though the semantic tree keeps it.
                if (node.hasTargetingSignal() && node.isVisible) {
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
                            occludedBy = occluderOf(node, currentWindow),
                        )
                    )
                }
                node.children.forEach { visit(it, currentWindow) }
            }
            visit(snapshot.rootRef, null)
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
    /**
     * What sits on top of this node's tap point, when anything does: the ref of
     * a higher z-order window (a dialog/popup covering a background page), or
     * [CompactObservation.OCCLUDER_KEYBOARD] for the system keyboard. A tap
     * dispatched at this item would land on the occluder instead.
     */
    val occludedBy: String? = null,
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
            occludedBy?.let { append(" occluded-by:$it") }
        }
        return "$selector $role$labelPart$framePart$state"
    }
}
