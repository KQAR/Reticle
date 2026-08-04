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

    /**
     * First node satisfying [match] in **document order**: depth-first from the
     * root, then any unreached ref in sorted order (an orphan window captured out
     * of band stays addressable, but never outranks a node that is in the tree).
     *
     * Deliberately not `nodes.values.firstOrNull` — that follows the map's
     * insertion order, i.e. whatever order the agent happened to serialize its
     * keys in, which is not a contract. The Swift twin had it worse: a
     * `Dictionary`'s order there is hash-seeded per process, so duplicate ids
     * resolved differently between two runs. Both sides now walk the tree, so
     * `reticle-protocol/fixtures/selector-resolution.cases.json` gets one answer.
     */
    /**
     * Every ref in **document order**: depth-first from the root, then any
     * unreached ref in sorted order — the ordering [firstNode] resolves in, made
     * available to whoever needs the whole list rather than the first match.
     *
     * Anything that presents or derives from the tree walks this instead of
     * `nodes.keys`, for the reason spelled out on [firstNode]: a map's order is a
     * decoding detail, and on the Swift side a `Dictionary`'s is hash-seeded per
     * process. Two projections ordered by map iteration cannot be pinned by a
     * shared fixture even when both are otherwise correct.
     */
    fun refsInDocumentOrder(): List<String> {
        val out = ArrayList<String>(nodes.size)
        val seen = HashSet<String>()
        fun visit(ref: String) {
            if (ref in seen) return
            val node = nodes[ref] ?: return
            seen += ref
            out += ref
            node.children.forEach(::visit)
        }
        visit(rootRef)
        nodes.keys.sorted().forEach(::visit)
        return out
    }

    fun firstNode(match: (Node) -> Boolean): Node? {
        val seen = HashSet<String>()
        fun visit(ref: String): Node? {
            if (!seen.add(ref)) return null
            val node = nodes[ref] ?: return null
            if (match(node)) return node
            for (child in node.children) visit(child)?.let { return it }
            return null
        }
        visit(rootRef)?.let { return it }
        for (ref in nodes.keys.sorted()) {
            if (ref !in seen) visit(ref)?.let { return it }
        }
        return null
    }

    /**
     * The in-app windows of this capture, bottom-most first — the application
     * root's `window` children, in the platform's stacking order (dialogs and
     * popups last).
     *
     * Stacking order is a fact of the capture, not a derivation: on Android the
     * application node's children ARE `WindowManagerGlobal.getRootViews()` in
     * z-order. It is the ordering both the occlusion test and window scoping use,
     * so it lives here rather than being re-walked at each call site.
     */
    fun windowRefs(): List<String> =
        root()?.children?.filter { nodes[it]?.kind == NodeKind.window } ?: emptyList()

    /** The window that is on top, or null when this capture has no window nodes. */
    fun topWindowRef(): String? = windowRefs().lastOrNull { nodes[it]?.isVisible != false }

    /**
     * The window a node belongs to — the nearest `window` ancestor, or null for a
     * node captured outside any window (the application root itself).
     */
    fun windowRefOf(ref: String): String? {
        var current = nodes[ref]
        val seen = HashSet<String>()
        while (current != null && seen.add(current.ref)) {
            if (current.kind == NodeKind.window) return current.ref
            current = current.parentRef?.let { nodes[it] }
        }
        return null
    }

    /**
     * This capture narrowed to ONE window, keeping the application root above it.
     *
     * A form pushed over a still-alive host screen puts both windows in one tree,
     * and every flat projection then interleaves them by geometry: the two
     * `#content` roots appear twice, a repeated framework id resolves ambiguously,
     * and the fields of the screen the user is actually looking at end up a dozen
     * aliases apart with unrelated content wedged between them. On Android a
     * stacked screen is the common case, not the exception.
     *
     * Scoping is done on the SNAPSHOT rather than in each renderer so every view —
     * `tree`, `compact`, `outline`, `style`, and the `@N` alias numbering that
     * follows from them — narrows identically, and so nothing else has to learn
     * about windows.
     *
     * @param window a window ref, or `"top"` for the topmost visible one.
     * @return the narrowed snapshot, or null when [window] names no window here.
     */
    fun scopedToWindow(window: String): Snapshot? {
        val targetRef = if (window == TOP_WINDOW) topWindowRef() else window.takeIf { it in windowRefs() }
        val target = targetRef?.let { nodes[it] } ?: return null
        val kept = LinkedHashMap<String, Node>()
        val rootNode = root()
        if (rootNode != null) kept[rootNode.ref] = rootNode.copy(children = listOf(target.ref))
        fun visit(ref: String) {
            val node = nodes[ref] ?: return
            if (kept.put(ref, node) != null) return
            node.children.forEach(::visit)
        }
        visit(target.ref)
        return copy(nodes = kept)
    }

    companion object {
        /** [scopedToWindow] argument for "whatever window is on top right now". */
        const val TOP_WINDOW = "top"

        /**
         * The wire format version this build emits. Must equal the `const` on
         * `schemaVersion` in snapshot.schema.json — ProtocolContractTest pins the
         * two together so the code and the authoritative schema can't drift.
         * Bump both, in lockstep, on an incompatible wire change.
         */
        const val SCHEMA_VERSION = 1
    }
}

/**
 * A snapshot whose wire format is NEWER than this build understands.
 *
 * Thrown at ingestion, not at decode: both JSON configurations ignore unknown
 * keys (they must, for additive changes), so a v2 producer's renamed field
 * would otherwise decode silently into a default — `isVisible=true` for a
 * field that moved — and the projection would present invented evidence as
 * real. An observer that cannot read the input says so; it does not guess.
 */
class UnsupportedSnapshotSchema(found: Int) : RuntimeException(
    "snapshot schemaVersion=$found is newer than this build understands " +
        "(max ${Snapshot.SCHEMA_VERSION}). Upgrade the host/helper to at least the " +
        "agent's version — a newer producer's fields would silently decode as defaults."
)

/**
 * Gate every snapshot INGESTED from outside this process (agent HTTP, a
 * `--snapshot` file) — see [UnsupportedSnapshotSchema]. Returns the snapshot so
 * ingestion sites can stay one expression.
 */
fun Snapshot.requireSupportedSchema(): Snapshot {
    if (schemaVersion > Snapshot.SCHEMA_VERSION) throw UnsupportedSnapshotSchema(schemaVersion)
    return this
}

/**
 * The channel a style property was read through — the provenance half of
 * [Node.styleChannels].
 *
 * Channels differ in what they can be trusted for, so collapsing them would hide
 * the difference: a `viewField` read is the live value the platform will render,
 * while a `drawableReflect` read walked a private `Drawable` field and can be
 * stale on a themed or animated background. A consumer that compares against a
 * design needs to know which it is holding.
 */
@Serializable
enum class StyleChannel {
    /** A public field/getter on the platform view or its layer. */
    viewField,

    /** Compose: the `TextStyle` behind a laid-out `Text`, via `GetTextLayoutResult`. */
    textLayout,

    /** WebView: `getComputedStyle` on the DOM element. */
    computedStyle,

    /** Reflected out of an Android background `Drawable` — see the caveat above. */
    drawableReflect,
}

/**
 * Toggle state of a checkable control. See [Node.checked].
 *
 * Modelled as a nullable enum rather than a `Boolean` because the absence of a
 * value is itself an answer: "this node is not a checkable control" and "this
 * node is a checkbox and it is unticked" lead to opposite next actions, and a
 * `Boolean` defaulting to false collapses them into the second one.
 */
@Serializable
enum class CheckedState {
    on,
    off,

    /**
     * A tri-state control — a "select all" covering a partial selection.
     * `aria-checked="mixed"`, Compose `ToggleableState.Indeterminate`.
     */
    mixed,
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
    /**
     * Can this node take input focus **from a touch**? (Android:
     * `focusableInTouchMode`, not `isFocusable` — since API 26 a plain clickable
     * container reports `isFocusable = true` under `FOCUSABLE_AUTO` while a tap
     * moves no focus into it, which is exactly the confusion this field exists to
     * remove. Reticle drives touches, so the touch reading is the useful one.)
     *
     * Distinct from [isInteractive], which is true for anything clickable: the
     * shape that motivated this is an outer container carrying the stable test id
     * — clickable, and often the only unique handle — wrapping the `EditText`
     * that actually accepts text. Targeting the container used to type into
     * nothing at all.
     *
     * False on a node whose platform has no per-node focus channel (Compose
     * semantics, DOM elements): there the platform focus sits on the host view,
     * which is this node's ancestor.
     */
    val isFocusable: Boolean = false,
    /**
     * Does this node hold input focus right now? At most one node in a tree does.
     * The post-condition `act type` checks: after tapping the target field, the
     * focused node must be that node or inside it, or the text is about to land
     * somewhere else.
     */
    val isFocused: Boolean = false,
    /**
     * Toggle state of a checkable control, or null when this node is not
     * checkable at all. See [CheckedState] for why the third state is `null`
     * rather than `false`.
     *
     * Sources, in the order each platform offers one: an Android [Checkable]
     * view (`CheckBox`, `Switch`, `RadioButton`), Compose's `ToggleableState` /
     * `Selected` semantics, a DOM `input[type=checkbox|radio]`'s `checked`
     * property, then `aria-checked` / `aria-pressed` for a control a framework
     * built out of divs.
     *
     * The shape this exists for: a consent row projected as `role: checkbox`
     * with no state anywhere on the node, so the only way to read whether a tap
     * ticked it was a screenshot.
     */
    val checked: CheckedState? = null,
    /**
     * Disclosure state of a control that opens something (`aria-expanded`), or
     * null when this node declares none.
     *
     * Null and `false` are different facts for the same reason [checked] keeps its
     * third state: "this is not a disclosure control" and "it is one and it is
     * shut" lead to opposite next actions. Reading it is also the only way to
     * verify that a tap on a dropdown trigger did anything — a div-built select
     * materialises its options only once opened, so before the tap there is
     * nothing to diff against.
     */
    val expanded: Boolean? = null,
    /** Scalar reflected properties, e.g. alpha, backgroundColor, elevation. */
    val custom: Map<String, MetadataValue> = emptyMap(),
    /**
     * Where each style-bearing entry of [custom] was read from. Keyed by the same
     * property name; absent for properties that are not style (ids, DOM
     * bookkeeping, app-authored metadata).
     *
     * This exists because "the design says 600, the app has nothing" has two very
     * different causes — the app really did not set a weight, or Reticle has no
     * channel to that weight — and a consumer comparing against a design cannot
     * tell them apart from a missing key. Naming the channel makes the value
     * checkable rather than believed, the same rule `custom.domKernel` follows.
     */
    val styleChannels: Map<String, StyleChannel> = emptyMap(),
    /**
     * Style properties this node is known to HAVE but which no channel can read,
     * keyed by property name with a short reason as the value (e.g.
     * `backgroundColor` -> `compose-draw-modifier`).
     *
     * The boundary rule at property granularity: an unreachable thing must
     * produce evidence naming itself, never silence. A key here is never also a
     * key of [custom] or [styleChannels].
     */
    val styleGaps: Map<String, String> = emptyMap(),
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
    /**
     * True when this node looks like a WHEEL column — a control that paints its
     * candidate values onto its own canvas instead of materialising them as nodes.
     *
     * A hint from the widget's class family, not a claim, and the reason it exists
     * is that a wheel is otherwise indistinguishable from a decorative empty view:
     * three rectangles, no items, no selected value, no `scroll:` travel, no
     * regions. A caller reading that has no cue to switch tactics and ends up
     * measuring row pitch off a screenshot — four screenshot round-trips and a
     * hand-derived pixel constant for what is semantically "select 1995".
     *
     * What the marker says is exactly what is true: the values are pixels, so
     * reaching another one is a `swipe` along the column and the evidence it
     * worked is the app's own committed state, never a node appearing.
     * `scroll-to` cannot help — no selector for an unselected value can ever
     * resolve. See docs/boundaries.md.
     */
    val suspectedWheel: Boolean = false,
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
    /**
     * True when this node hosts a web view whose DOM could not be read at capture
     * time. The agents set `custom["domStatus"] = "unavailable"` in that case; this
     * is the single place that spelling is interpreted.
     */
    fun domUnavailable(): Boolean =
        (custom["domStatus"] as? MetadataValue.Text)?.value == "unavailable"

    /**
     * What kind of popup this control declares it opens (`aria-haspopup`), or null.
     * `listbox` for a div-built select, `menu` for the attribute's bare `true`.
     *
     * A hint the PAGE published, not one Reticle inferred — which is what makes it
     * worth acting on: a control that says it opens a listbox is one whose options
     * appear after a tap, so an empty tree under it is expected rather than
     * evidence that nothing is there.
     */
    fun domHasPopup(): String? = (custom["domHasPopup"] as? MetadataValue.Text)?.value

    /** A DOM input's `placeholder` attribute, kept apart from its value. */
    fun domPlaceholder(): String? = (custom["domPlaceholder"] as? MetadataValue.Text)?.value

    /**
     * This element's 1-based position among its siblings, as the PAGE counted it:
     * [domNthOfType] among siblings with the same tag, [domNthChild] among all
     * element children.
     *
     * Read in the page rather than derived from the captured tree, because the walk
     * drops `display:none` / `visibility:hidden` elements — counting captured
     * children would answer `:nth-of-type(3)` with the third VISIBLE sibling, which
     * looks plausible and taps the wrong control.
     */
    fun domNthOfType(): Int? = (custom["domNthOfType"] as? MetadataValue.Integer)?.value?.toInt()

    /** See [domNthOfType]. */
    fun domNthChild(): Int? = (custom["domNthChild"] as? MetadataValue.Integer)?.value?.toInt()

    /**
     * The message this field declares itself invalid with: `""` when it sets
     * `aria-invalid` and points at nothing, the `aria-describedby` text when it
     * does, and null when the field does not declare itself invalid at all.
     *
     * Three states rather than two because "valid" and "invalid, reason not
     * stated" are different readings, and only the first means there is nothing
     * to fix.
     */
    fun domInvalidMessage(): String? {
        val invalid = (custom["domInvalid"] as? MetadataValue.Bool)?.value ?: false
        if (!invalid) return null
        return (custom["domDescribedBy"] as? MetadataValue.Text)?.value ?: ""
    }

    /**
     * True when this node's pixels are NOT in an in-process screenshot: an Android
     * `SurfaceView` draws into its own surface (composited by SurfaceFlinger, so the
     * agent's Canvas walk leaves a transparent hole where the video/GL content is),
     * and an iOS keyboard host window refuses to render into a borrowed context.
     * Measured, not assumed — see `scenario.screenshotDegrade`. Agents set
     * `custom["pixelStatus"] = "unavailable"`; this is the single place that
     * spelling is interpreted.
     */
    /**
     * True when this node is a **suspected third-party WebView kernel** (X5/TBS,
     * UC, …): a class whose name says WebView but which is not an
     * `android.webkit.WebView`, so `WebViewBridge` — typed on the platform class —
     * cannot attach and there is NO DOM for this view at any level. Unlike
     * [domUnavailable], which is a transient read failure, this is a structural
     * boundary: retrying, waiting, or dismissing a modal will never produce DOM
     * nodes here. `custom["domKernel"]` carries the class that triggered it, so the
     * claim can be checked rather than believed.
     */
    fun domKernelUnsupported(): Boolean =
        (custom["domStatus"] as? MetadataValue.Text)?.value == "unsupportedKernel"

    /** The class name behind [domKernelUnsupported], for reporting. */
    fun domKernelName(): String? =
        (custom["domKernel"] as? MetadataValue.Text)?.value

    fun pixelsUnavailable(): Boolean =
        (custom["pixelStatus"] as? MetadataValue.Text)?.value == "unavailable"

    /**
     * The CSS selector a WebView DOM node was emitted with, the twin of the Swift
     * `Node.domCssSelector()`. Present only on `NodeKind.domNode`.
     *
     * Lives here rather than in the helper because selector resolution — which is
     * pinned across both languages by
     * `reticle-protocol/fixtures/selector-resolution.cases.json` — reads it, and the
     * key/cast must be spelled once.
     */
    /**
     * How many DOM nodes were captured before the traversal hit its own node cap,
     * or null when it walked the whole document.
     *
     * The projection's cap already announces itself
     * (`(N more item(s) beyond this projection's cap …)`); the traversal's stopped
     * silently, so a partial DOM read as the whole page — and unlike the
     * projection's, nothing further down can recover what was never captured.
     */
    fun domCappedAt(): Long? {
        val capped = (custom["domCapped"] as? MetadataValue.Bool)?.value ?: false
        if (!capped) return null
        return (custom["domCaptured"] as? MetadataValue.Integer)?.value ?: 0L
    }

    /**
     * True when this is an `<iframe>` whose document the page may not read.
     *
     * A structural boundary — browser policy, which nothing in the app can
     * override — and previously an unmarked one: the frame element was captured
     * with its rect and no children, which is byte-for-byte what a frame that has
     * not finished loading looks like. A caller that cannot tell those apart
     * retries, waits, and ends up measuring pixels off a screenshot. Measured on a
     * real third-party widget: four consecutive steps done by coordinate because
     * the tree gave no reason to stop trying.
     */
    fun domCrossOriginFrame(): Boolean =
        (custom["domCrossOriginFrame"] as? MetadataValue.Bool)?.value ?: false

    /** The element's tag name, lowercased by the traversal script. */
    fun domTag(): String? = (custom["domTag"] as? MetadataValue.Text)?.value

    /** The element's `id` attribute. Also mirrored into [testId]. */
    fun domId(): String? = (custom["domId"] as? MetadataValue.Text)?.value

    /** The element's class list, split from the captured `class` attribute. */
    fun domClasses(): List<String> =
        (custom["domClass"] as? MetadataValue.Text)?.value
            ?.split(' ', '\t', '\n')
            ?.filter { it.isNotBlank() }
            ?: emptyList()

    fun domCssSelector(): String? =
        (custom["domCssSelector"] as? MetadataValue.Text)?.value

    /**
     * The mirror image: this window is `FLAG_SECURE`, so a DEVICE-level capture
     * (`adb exec-out screencap`) comes back blanked while the in-process capture is
     * unaffected. Agents set `custom["screencapStatus"] = "blank"`.
     */
    fun screencapBlank(): Boolean =
        (custom["screencapStatus"] as? MetadataValue.Text)?.value == "blank"

    fun hasTargetingSignal(): Boolean =
        testId != null ||
            resourceId != null ||
            contentDescription != null ||
            !text.isNullOrBlank() ||
            isInteractive ||
            // A DISABLED input is not interactive and, on a form built from
            // framework components, carries no id, no label and no value — so
            // every other clause above is false and it used to be filtered out of
            // the projection entirely. Measured: an address form's city/street
            // fields, disabled until a postcode unlocked them, were simply not on
            // screen as far as the compact view was concerned, which reads as "the
            // app does not have those fields" rather than "they are not ready yet".
            // The placeholder is both the signal that it IS a field and the only
            // thing that says which one.
            domPlaceholder() != null
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
