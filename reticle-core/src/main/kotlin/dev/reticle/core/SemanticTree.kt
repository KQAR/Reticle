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

    /** The root node; always resolves because [build] guarantees [rootRef] exists. */
    fun root(): SemanticNode? = nodes[rootRef]

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
            // 1. Which nodes carry a targeting signal and are therefore kept.
            val kept = from.nodes.keys.filter { ref ->
                from.nodes[ref]?.hasTargetingSignal() == true
            }.toHashSet()

            // 2. Nearest kept ancestor of a ref, walking parentRef upward.
            //    Used both to reparent kept nodes and to lift a dropped node's
            //    children onto the kept node above them, so the tree stays
            //    connected through kept nodes only.
            fun nearestKeptAncestor(ref: String): String? {
                var cur = from.nodes[ref]?.parentRef
                while (cur != null) {
                    if (cur in kept) return cur
                    cur = from.nodes[cur]?.parentRef
                }
                return null
            }

            // 3. Kept children of a ref: its nearest kept descendants along each
            //    branch (skipping dropped intermediate nodes), preserving order.
            fun keptDescendants(ref: String): List<String> {
                val out = ArrayList<String>()
                fun collect(childRef: String) {
                    if (childRef in kept) {
                        out.add(childRef)
                    } else {
                        from.nodes[childRef]?.children?.forEach(::collect)
                    }
                }
                from.nodes[ref]?.children?.forEach(::collect)
                return out
            }

            val nodes = LinkedHashMap<String, SemanticNode>()
            for (ref in kept) {
                val node = from.nodes[ref] ?: continue
                nodes[ref] = SemanticNode(
                    ref = ref,
                    parentRef = nearestKeptAncestor(ref),
                    role = node.role ?: node.typeName,
                    label = node.contentDescription ?: node.text,
                    resourceId = node.resourceId,
                    testId = node.testId,
                    frame = node.frame,
                    isEnabled = node.isEnabled,
                    isInteractive = node.isInteractive,
                    children = keptDescendants(ref),
                )
            }

            // 4. The snapshot root almost never carries a targeting signal (the
            //    Application node), so it is dropped and cannot be the semantic
            //    root. Synthesize a lightweight root under the same ref that holds
            //    every top-level kept node (those with no kept ancestor), so
            //    root()/node(rootRef) resolve and the whole kept set is reachable
            //    by walking children. If the real root happened to be kept, use
            //    it as-is.
            val rootRef = from.rootRef
            if (rootRef !in nodes) {
                val topLevel = nodes.values
                    .filter { it.parentRef == null }
                    .map { it.ref }
                // Reparent the top-level kept nodes onto the synthesized root so
                // the parent/child links agree in both directions.
                for (ref in topLevel) {
                    nodes[ref] = nodes.getValue(ref).copy(parentRef = rootRef)
                }
                val rootNode = from.nodes[rootRef]
                nodes[rootRef] = SemanticNode(
                    ref = rootRef,
                    parentRef = null,
                    role = rootNode?.role ?: rootNode?.typeName ?: "root",
                    children = topLevel,
                )
            }
            return SemanticTree(rootRef = rootRef, nodes = nodes)
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
