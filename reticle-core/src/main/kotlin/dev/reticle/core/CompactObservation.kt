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

            /**
             * How much of a wheel column is readable, or null when this is not one.
             *
             * Two shapes, and collapsing them would be a lie in one direction or the
             * other: an Android `NumberPicker` keeps its SELECTION as a child node
             * (`selection-only` — the current value is readable, the neighbours are
             * pixels), while a self-drawn wheel publishes nothing at all (`opaque`).
             * Either way the unselected values are unreachable and the control must
             * be driven with `swipe`.
             */
            fun wheelMarkerFor(snapshot: Snapshot, node: Node): String? {
                if (!node.suspectedWheel) return null
                val seen = HashSet<String>()
                fun hasTextInside(ref: String): Boolean {
                    val child = snapshot.nodes[ref] ?: return false
                    if (!seen.add(ref)) return false
                    if (ref != node.ref && !child.text.isNullOrBlank()) return true
                    return child.children.any(::hasTextInside)
                }
                return if (hasTextInside(node.ref)) "selection-only" else "opaque"
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
                            scroll = node.scroll,
                            wheel = wheelMarkerFor(snapshot, node),
                            domUnavailable = node.domUnavailable(),
                            domKernelUnsupported = node.domKernelUnsupported(),
                            pixelsUnavailable = node.pixelsUnavailable(),
                            screencapBlank = node.screencapBlank(),
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
    /**
     * Scroll capability when this item is a scrollable container. An agent needs
     * it to tell "this selector doesn't exist" from "it isn't bound yet because
     * the list hasn't been scrolled there".
     */
    val scroll: ScrollInfo? = null,
    /**
     * `"opaque"` / `"selection-only"` when this item is a wheel column, else null.
     * Rendered as `wheel:<value>` — the honest-boundary marker for a control whose
     * candidate values exist only as pixels. See [Node.suspectedWheel].
     */
    val wheel: String? = null,
    /**
     * True when this node hosts a web view whose DOM could not be read at capture
     * time (a JS modal blocking the page's thread, JS disabled, or a read that
     * outran its budget). Without it, "no DOM nodes" and "this web view is empty"
     * are the same observation.
     */
    val domUnavailable: Boolean = false,
    /**
     * True when this node's pixels are missing from an IN-PROCESS screenshot (an
     * Android `SurfaceView`, an iOS keyboard host window). The picture is not a
     * second opinion for these — it silently omits them.
     */
    /**
     * True when this node is a suspected third-party WebView kernel (X5/UC): no DOM
     * bridge exists for it at all. A structural boundary, not a transient degrade.
     */
    val domKernelUnsupported: Boolean = false,
    val pixelsUnavailable: Boolean = false,
    /**
     * True when this window is `FLAG_SECURE`: the DEVICE-level capture is blanked,
     * the in-process one is not. The complement of [pixelsUnavailable].
     */
    val screencapBlank: Boolean = false,
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
            scroll?.describe()?.takeIf { it.isNotEmpty() }?.let { append(" ").append(it) }
            wheel?.let { append(" wheel:").append(it) }
            if (domUnavailable) append(" dom:unavailable")
            if (domKernelUnsupported) append(" dom:unsupported-kernel")
            if (pixelsUnavailable) append(" pixels:unavailable")
            if (screencapBlank) append(" screencap:blank")
        }
        return "$selector $role$labelPart$framePart$state"
    }
}
