package dev.reticle.core

import kotlinx.serialization.Serializable

/**
 * The accessibility / semantics tree.
 *
 * Architecture rule: use the accessibility tree FIRST for movement and input;
 * selector actions only fall back to view frames when no accessibility match
 * exists. On Android this tree is built from the View hierarchy's accessibility
 * properties (and, for Compose, the merged SemanticsNode tree exposed through
 * accessibility).
 */
@Serializable
data class AccessibilityTree(
    val rootRef: String,
    val nodes: Map<String, AccessibilityNode>,
) {
    fun node(ref: String): AccessibilityNode? = nodes[ref]

    /** Find a node by stable selector id (Compose testTag / app id). */
    fun findByTestId(testId: String): AccessibilityNode? =
        nodes.values.firstOrNull { it.testId == testId }

    /** Find by resource-id entry name. */
    fun findByResourceId(resourceId: String): AccessibilityNode? =
        nodes.values.firstOrNull { it.resourceId == resourceId }

    companion object {
        /**
         * Build an accessibility view from a snapshot, keeping only nodes that
         * carry an accessibility-relevant signal (label, id, or interactivity).
         */
        fun build(from: Snapshot): AccessibilityTree {
            val nodes = LinkedHashMap<String, AccessibilityNode>()
            for ((ref, node) in from.nodes) {
                val accessible = node.contentDescription != null ||
                    node.testId != null ||
                    node.resourceId != null ||
                    node.text != null ||
                    node.isInteractive
                if (!accessible) continue
                nodes[ref] = AccessibilityNode(
                    ref = ref,
                    parentRef = node.parentRef,
                    role = node.role ?: node.typeName,
                    label = node.contentDescription ?: node.text,
                    resourceId = node.resourceId,
                    testId = node.testId,
                    frame = node.frame,
                    isEnabled = node.isEnabled,
                    isInteractive = node.isInteractive,
                    children = node.children.filter { from.nodes.containsKey(it) },
                )
            }
            return AccessibilityTree(rootRef = from.rootRef, nodes = nodes)
        }
    }
}

@Serializable
data class AccessibilityNode(
    val ref: String,
    val parentRef: String? = null,
    val role: String,
    val label: String? = null,
    val resourceId: String? = null,
    val testId: String? = null,
    val frame: Rect? = null,
    val isEnabled: Boolean = true,
    val isInteractive: Boolean = false,
    val children: List<String> = emptyList(),
)
