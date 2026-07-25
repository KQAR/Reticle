package dev.reticle.core

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable

/**
 * The view-tree snapshot: a flat map of ref -> node plus a root ref, so a
 * subtree can be rehydrated by walking children refs.
 *
 * On Android the tree is rooted at the application, then each attached window
 * root view (WindowManagerGlobal.getRootViews), then the View hierarchy.
 */
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class Snapshot(
    // schema-`required`, but defaulted here — pin it so the omit-defaults wire
    // config in ReticleJson can never drop it.
    @EncodeDefault(EncodeDefault.Mode.ALWAYS) val schemaVersion: Int = SCHEMA_VERSION,
    /** Wall-clock millis when captured, stamped by the agent. */
    val capturedAtMillis: Long,
    @EncodeDefault(EncodeDefault.Mode.ALWAYS) val platform: String = "android",
    val screen: ScreenInfo,
    val rootRef: String,
    val nodes: Map<String, Node>,
) {
    fun node(ref: String): Node? = nodes[ref]

    fun root(): Node? = nodes[rootRef]

    fun children(ref: String): List<Node> =
        nodes[ref]?.children?.mapNotNull { nodes[it] } ?: emptyList()

    companion object {
        /**
         * The wire format version this build emits. Must equal the `const` on
         * `schemaVersion` in snapshot.schema.json — ProtocolContractTest pins the
         * two together so the code and the authoritative schema can't drift.
         * Bump both, in lockstep, on an incompatible wire change.
         */
        const val SCHEMA_VERSION = 1
    }
}

@Serializable
enum class NodeKind {
    application,
    window,
    view,
    composeSemantics, // an Android Compose accessibility-backed node
    axElement, // an iOS accessibility-derived SwiftUI element (the SwiftUI analogue of composeSemantics)
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
    /**
     * Scroll capability, when this node is a scrollable container. Absent for
     * ordinary nodes. See [ScrollInfo] — it is why "selector not found" can be
     * told apart from "the element isn't in this app".
     */
    val scroll: ScrollInfo? = null,
) {
    /**
     * True when this node carries a signal an agent can target it by: a stable
     * id, an a11y label, non-blank visible text, or interactivity. The single
     * source of truth for "is this worth keeping" — shared by the semantic-tree
     * and compact-observation projections so the two can never silently disagree
     * about which nodes are targetable.
     */
    fun hasTargetingSignal(): Boolean =
        testId != null ||
            resourceId != null ||
            contentDescription != null ||
            !text.isNullOrBlank() ||
            isInteractive
}

/**
 * A container's scroll capability, present only on nodes that have one.
 *
 * This is the missing evidence behind the commonest E2E dead end: a recycling
 * list keeps only its visible window bound, so a far-down row is not merely
 * off-viewport — it has no node, no frame, and no selector at all. Without this,
 * a `RecyclerView` / `LazyColumn` / `UIScrollView` looks like any other
 * container, and "selector not found" is indistinguishable from "the app doesn't
 * have that element".
 *
 * The four flags are the honest, cheaply-true facts: whether the container can
 * still move in each direction right now (Android `View.canScrollVertically`,
 * Compose's scroll-axis ranges, iOS content offset vs content size). They are
 * NOT a claim about what would come into view — Reticle emits evidence, and
 * where a missing element actually lives is not knowable from here.
 */
@Serializable
data class ScrollInfo(
    val canScrollUp: Boolean = false,
    val canScrollDown: Boolean = false,
    val canScrollLeft: Boolean = false,
    val canScrollRight: Boolean = false,
) {
    val isScrollable: Boolean
        get() = canScrollUp || canScrollDown || canScrollLeft || canScrollRight

    /** Compact rendering, e.g. "scroll:down" / "scroll:up,down". */
    fun describe(): String = buildString {
        val parts = ArrayList<String>(4)
        if (canScrollUp) parts.add("up")
        if (canScrollDown) parts.add("down")
        if (canScrollLeft) parts.add("left")
        if (canScrollRight) parts.add("right")
        if (parts.isNotEmpty()) append("scroll:").append(parts.joinToString(","))
    }
}
