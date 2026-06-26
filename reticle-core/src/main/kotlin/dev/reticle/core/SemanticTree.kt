package dev.reticle.core

import kotlinx.serialization.Serializable

/**
 * The semantic tree: the subset of the view snapshot that carries a usable
 * targeting signal (a label, a stable id, or interactivity), projected to a
 * compact per-node shape for selector resolution.
 *
 * What this is NOT: it is **not** the platform accessibility tree that
 * `uiautomator` / an `AccessibilityService` would dump. That tree is the
 * cross-process `AccessibilityNodeInfo` hierarchy the system builds — it honors
 * `importantForAccessibility`, carries a11y actions/state, and can be reshaped
 * by the app's `onInitializeAccessibilityNodeInfo`. This tree is derived purely
 * from the in-process View hierarchy (and merged Compose semantics already in
 * the snapshot), so it keeps nodes the platform a11y tree would hide and omits
 * a11y-only metadata. For locating and driving elements that distinction is a
 * feature: a target marked `importantForAccessibility=no` is still resolvable.
 *
 * Architecture rule: use the semantic tree FIRST for movement and input;
 * selector actions only fall back to raw view frames when no semantic match
 * exists.
 */
@Serializable
data class SemanticTree(
    val rootRef: String,
    val nodes: Map<String, SemanticNode>,
) {
    fun node(ref: String): SemanticNode? = nodes[ref]

    /** Find a node by stable selector id (Compose testTag / app id). */
    fun findByTestId(testId: String): SemanticNode? =
        nodes.values.firstOrNull { it.testId == testId }

    /** Find by resource-id entry name. */
    fun findByResourceId(resourceId: String): SemanticNode? =
        nodes.values.firstOrNull { it.resourceId == resourceId }

    companion object {
        /**
         * Build a semantic view from a snapshot, keeping only nodes that carry a
         * targeting signal (label, id, or interactivity).
         */
        fun build(from: Snapshot): SemanticTree {
            val nodes = LinkedHashMap<String, SemanticNode>()
            for ((ref, node) in from.nodes) {
                val hasSignal = node.contentDescription != null ||
                    node.testId != null ||
                    node.resourceId != null ||
                    node.text != null ||
                    node.isInteractive
                if (!hasSignal) continue
                nodes[ref] = SemanticNode(
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
            return SemanticTree(rootRef = from.rootRef, nodes = nodes)
        }
    }
}

@Serializable
data class SemanticNode(
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
