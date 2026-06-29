package dev.reticle.core

import kotlinx.serialization.Serializable

/**
 * The view-tree snapshot: a flat map of ref -> node plus a root ref, so a
 * subtree can be rehydrated by walking children refs.
 *
 * On Android the tree is rooted at the application, then each attached window
 * root view (WindowManagerGlobal.getRootViews), then the View hierarchy.
 */
@Serializable
data class Snapshot(
    val schemaVersion: Int = 1,
    /** Wall-clock millis when captured, stamped by the agent. */
    val capturedAtMillis: Long,
    val platform: String = "android",
    val screen: ScreenInfo,
    val rootRef: String,
    val nodes: Map<String, Node>,
) {
    fun node(ref: String): Node? = nodes[ref]

    fun root(): Node? = nodes[rootRef]

    fun children(ref: String): List<Node> =
        nodes[ref]?.children?.mapNotNull { nodes[it] } ?: emptyList()
}

@Serializable
enum class NodeKind {
    application,
    window,
    view,
    composeSemantics, // a Compose accessibility-backed node
    domNode, // a read-only DOM element captured from an embedded WebView
    probe,
}

/**
 * A single node in the unified UI tree: stable ref, parent/child links, frame in
 * screen coordinates, interaction flags, and a bag of scalar custom properties
 * reflected from the underlying View/semantics/DOM surface.
 */
@Serializable
data class Node(
    val ref: String,
    val parentRef: String? = null,
    val kind: NodeKind,
    /** Class name, e.g. "android.widget.Button" or a Compose role. */
    val typeName: String,
    val role: String? = null,
    /** Android resource-id entry name, e.g. "checkout_pay_button". */
    val resourceId: String? = null,
    /** contentDescription / Compose contentDescription — the a11y label. */
    val contentDescription: String? = null,
    /** Visible text for TextViews / Compose text nodes. */
    val text: String? = null,
    /**
     * Stable selector id. On Android this is the Compose testTag or an
     * app-attached id.
     */
    val testId: String? = null,
    val frame: Rect? = null,
    val isVisible: Boolean = true,
    val isEnabled: Boolean = true,
    val isInteractive: Boolean = false,
    /** Scalar reflected properties, e.g. alpha, backgroundColor, elevation. */
    val custom: Map<String, MetadataValue> = emptyMap(),
    val children: List<String> = emptyList(),
    /**
     * Discovered sub-regions within this single node (ClickableSpan ranges,
     * virtual a11y sub-nodes, touch-delegate rects). Empty for ordinary nodes.
     * See [InteractionRegion].
     */
    val regions: List<InteractionRegion> = emptyList(),
    /**
     * True when this looks like a multi-region control whose sub-regions could
     * NOT be recovered through any documented channel (e.g. a self-drawn widget
     * that handles hit testing privately). A hint for agents, not a claim:
     * pair with [charGrid] to target a substring by coordinate.
     */
    val suspectedMultiRegion: Boolean = false,
    /** Character-position grid for text nodes; enables substring targeting. */
    val charGrid: CharGrid? = null,
)
