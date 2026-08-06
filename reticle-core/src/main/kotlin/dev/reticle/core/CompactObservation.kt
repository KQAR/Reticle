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
    /**
     * How many anonymous layers were folded into the named items above (see the
     * fold rule in this file). Zero on a tree that had none. Reported so a
     * token-cheap projection never quietly claims to be the whole picture — the
     * folded nodes are all still in the snapshot, addressable by ref.
     */
    val collapsedWrappers: Int = 0,
    /**
     * How many items past the projection cap were DROPPED, not just folded. Zero
     * when everything fit. Like [collapsedWrappers], this exists so the cap can
     * never silently read as "that was the whole screen": the dropped nodes are
     * still in the snapshot, and a consumer that needs them must go there.
     */
    val truncatedItems: Int = 0,
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
            val windowRefs = snapshot.windowRefs()
            val windowOrder = windowRefs.withIndex().associate { (i, ref) -> ref to i }
            val keyboardFrame = snapshot.screen.keyboard?.takeIf { it.visible }?.frame

            /**
             * A sibling drawn AFTER this node's branch, covering its tap point.
             *
             * Occlusion used to be window-level only, which misses the shape a
             * hybrid app really has: a second screen pushed over a still-alive one
             * *inside one window*. Measured on a fixture — two web containers in one
             * `FrameLayout`, the second full-bleed — the covered page's button was
             * projected as an ordinary `tappable` node, a tap on it reported
             * `settled=1`, and nothing happened: the touch went to the cover.
             *
             * Sibling order IS draw order for a View tree, so "later child of a
             * common ancestor" is the same relation the window loop above uses, one
             * level down. Walking only the ancestor chain keeps it O(depth x
             * siblings) rather than comparing every pair of nodes.
             *
             * Requires the cover to be **interactive**, which is the honest limit:
             * Android hands a touch to the topmost child that consumes it, and a
             * non-interactive view lets it fall through to what is underneath. A
             * decorative transparent frame therefore does not occlude, and is not
             * reported as doing so.
             */
            // A screen-sized interactive container occludes a point only where it
            // actually DRAWS something there.
            //
            // Two shapes look identical to geometry and are opposites in practice. A
            // second screen pushed over a live one inside one window really does eat
            // the touch — that is the `nestedWebViewsCovered` fixture, and its cover
            // has its own content at every point. A transparent full-screen frame
            // does not: measured on a login screen carrying an in-app debug overlay,
            // EVERY item came back `occluded-by:<overlay>` while every one of them
            // was tappable, which makes the marker useless exactly where it matters.
            //
            // The distinguisher is content, not size: a cover with a node of its own
            // at this point is a cover; a full-screen frame with nothing drawn here
            // is scenery. Small occluders are taken at face value — a floating
            // button 174px across is drawn where it says it is.
            val screenArea = snapshot.screen.size.width * snapshot.screen.size.height
            fun drawsAt(node: Node, cx: Double, cy: Double): Boolean {
                val frame = node.frame ?: return false
                if (frame.width * frame.height <= screenArea * ScreenCoverage.CONTAINER_AREA_FRACTION) {
                    return true
                }
                // A web view is opaque to touch wherever it lies, whether or not its
                // document happens to have an element at this exact point: the
                // native view consumes the event before the page is consulted. So a
                // second page pushed over a live one keeps occluding everything
                // under it even where its own DOM is sparse.
                if (node.role == "webView" || node.typeName.contains("WebView")) return true
                val seen = HashSet<String>()
                fun descendantAt(ref: String): Boolean {
                    if (!seen.add(ref)) return false
                    val child = snapshot.nodes[ref] ?: return false
                    if (child.isVisible && child.frame?.contains(cx, cy) == true &&
                        child.ref != node.ref
                    ) {
                        return true
                    }
                    return child.children.any(::descendantAt)
                }
                return node.children.any(::descendantAt)
            }

            // The keyboard's own host window and input view stay in the hierarchy
            // AFTER the keyboard is dismissed, still geometrically over whatever the
            // keys covered — measured on the iOS login screen: the submit button read
            // `occluded-by:<that window>` with `keyboard: hidden` on the line above,
            // which is a contradiction the caller cannot act on. Keyboard coverage has
            // its own channel (`occluded-by:keyboard`), computed from the keyboard's
            // reported frame, and that one clears on dismissal. So this subtree is
            // never node-level cover.
            fun insideKeyboardHost(ref: String): Boolean {
                var current: Node? = snapshot.nodes[ref]
                val walked = HashSet<String>()
                while (current != null && walked.add(current.ref)) {
                    if ((current.custom["keyboardHost"] as? MetadataValue.Bool)?.value == true) return true
                    current = current.parentRef?.let { snapshot.nodes[it] }
                }
                return false
            }

            fun laterSiblingCovering(node: Node, cx: Double, cy: Double): String? {
                var current = node
                var parent = current.parentRef?.let { snapshot.nodes[it] }
                val seen = HashSet<String>()
                while (parent != null && seen.add(parent.ref)) {
                    val siblings = parent.children
                    val position = siblings.indexOf(current.ref)
                    if (position >= 0) {
                        for (i in siblings.size - 1 downTo position + 1) {
                            val above = snapshot.nodes[siblings[i]] ?: continue
                            if (!above.isVisible || !above.isInteractive) continue
                            if (insideKeyboardHost(above.ref)) continue
                            if (!drawsAt(above, cx, cy)) continue
                            if (above.frame?.contains(cx, cy) == true) return above.ref
                        }
                    }
                    current = parent
                    parent = current.parentRef?.let { snapshot.nodes[it] }
                }
                return null
            }

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
                    if (insideKeyboardHost(above.ref)) continue
                    if (above.frame?.contains(cx, cy) == true) return above.ref
                }
                return laterSiblingCovering(node, cx, cy)
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
                // A wheel that publishes its own state: value, position in the range,
                // and the pixel pitch of one row. That last one is the number a caller
                // used to measure off a screenshot before calibrating a swipe by trial.
                val value = node.wheelValue()
                val index = node.wheelIndex()
                val min = node.wheelMin()
                val max = node.wheelMax()
                if (value != null && index != null && min != null && max != null) {
                    val out = StringBuilder("value=\"").append(value).append("\" ")
                        .append(index - min + 1).append("/").append(max - min + 1)
                    node.wheelRowHeightPx()?.let { pitch ->
                        out.append(" pitch=").append(pitch).append("px")
                        // Labelled, because `height / 3` is the platform default rather
                        // than a reading, and a swipe built on it can be off by a row.
                        if (node.wheelRowHeightEstimated()) out.append("~")
                    }
                    // The labels live on the node (`ui node`), not here: a year wheel has
                    // 120 of them and this line has to stay one line.
                    val items = node.wheelItems()
                    if (items.isNotEmpty()) out.append(" items")
                    return out.toString()
                }
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
            // Seen-set, matching the document-order contract used everywhere
            // else (`refsInDocumentOrder`, `SemanticTree.firstNode`): a children
            // cycle in a malformed snapshot must not recurse forever, and a ref
            // reachable under two parents is one item, not two.
            val seen = HashSet<String>()
            fun visit(ref: String, windowRef: String?) {
                if (!seen.add(ref)) return
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
                            // A control's VALUE owns the label slot and its NAME gets
                            // its own, whenever the node carries both and they differ.
                            // This started as a text-field rule and a real form showed
                            // why it cannot be: a component-library select is a
                            // `<button>` that displays the chosen value as its own text,
                            // so five of them projected as `button "<value>"` — five
                            // values with nothing saying which field each belonged to,
                            // the same defect the rule was written to fix, one element
                            // type over. A node with only one
                            // of the two still puts it in the label slot rather than
                            // leaving the line anonymous.
                            label = node.text?.takeIf { it.isNotEmpty() } ?: node.contentDescription,
                            name = node.contentDescription
                                ?.takeIf { !node.text.isNullOrEmpty() && it != node.text },
                            frame = node.frame,
                            isEnabled = node.isEnabled,
                            isInteractive = node.isInteractive,
                            windowRef = currentWindow,
                            isFocused = node.isFocused,
                            checked = node.checked,
                            expanded = node.expanded,
                            hasPopup = node.domHasPopup(),
                            placeholder = node.placeholder(),
                            invalid = node.domInvalidMessage(),
                            occludedBy = occluderOf(node, currentWindow),
                            scroll = node.scroll,
                            wheel = wheelMarkerFor(snapshot, node),
                            domUnavailable = node.domUnavailable(),
                            domCappedAt = node.domCappedAt(),
                            crossOriginFrame = node.domCrossOriginFrame(),
                            frameOpaque = node.domFrameOpaque(),
                            geometryApprox = node.domGeometryApprox(),
                            domKernelUnsupported = node.domKernelUnsupported(),
                            pixelsUnavailable = node.pixelsUnavailable(),
                            screencapBlank = node.screencapBlank(),
                        )
                    )
                }
                node.children.forEach { visit(it, currentWindow) }
            }
            visit(snapshot.rootRef, null)
            val folded = collapseWrappers(snapshot, items)
            val kept = keepMostActionable(folded.items, maxItems)
            return CompactObservation(
                capturedAtMillis = snapshot.capturedAtMillis,
                screen = snapshot.screen,
                items = kept,
                collapsedWrappers = folded.collapsed,
                truncatedItems = folded.items.size - kept.size,
            )
        }
    }
}

/**
 * Which items survive the cap when the screen has more than fits.
 *
 * Taking the first N in document order is the obvious rule and it fails badly on
 * exactly the screens the cap exists for. Measured on a hybrid form: the page led
 * with a decorative digit-roller — a `<ul>` of 27 hidden `<li>` elements, each
 * rendering as "9 8 7 6 5 4 3 2 1 0 …", plus its wrapper divs — and those ate the
 * whole budget. The projection showed a screen full of odometer digits and NOT ONE
 * of the form's inputs, its labels or its submit button, all of which were present
 * in the snapshot. The caller reads "there are no controls here".
 *
 * So the budget is spent by usefulness, not by position:
 *
 *  - **2** — a control: interactive, or a role that only a control has. This is
 *    what the caller can act on, and dropping it is what turned a form into
 *    nothing.
 *  - **1** — nameable content: an id, a label, or visible text of its own.
 *  - **0** — everything else: containers and anonymous rectangles.
 *
 * Ranks are then filled in order, and each rank keeps DOCUMENT order inside
 * itself, so the surviving items still read top-to-bottom as they appear on
 * screen. Nothing is reordered in the output — the selection changes, not the
 * layout.
 */
private fun keepMostActionable(items: List<CompactItem>, maxItems: Int): List<CompactItem> {
    if (items.size <= maxItems) return items
    val byRank = items.withIndex().sortedWith(
        compareByDescending<IndexedValue<CompactItem>> { rankOf(it.value) }.thenBy { it.index }
    )
    return byRank.take(maxItems).sortedBy { it.index }.map { it.value }
}

/** How much of the cap this item deserves — see [keepMostActionable]. */
private fun rankOf(item: CompactItem): Int {
    if (item.isInteractive || item.role in CONTROL_ROLES) return 2
    if (item.testId != null || item.resourceId != null || !item.label.isNullOrBlank()) return 1
    return 0
}

/**
 * Roles that are a control even when the platform did not mark them interactive —
 * a disabled input is still the thing the caller is looking for, and a DOM
 * `checkbox` whose click handler lives in JS is not flagged tappable at all.
 */
private val CONTROL_ROLES = setOf(
    "button", "textField", "checkbox", "radio", "switch", "slider", "link", "menuItem", "tab",
)

/** The item list after folding, and how many anonymous layers went into it. */
private data class Folded(val items: List<CompactItem>, val collapsed: Int)

/**
 * Fold anonymous layers into the named node they sit on.
 *
 * UI toolkits build one on-screen row out of several views, and only one of them
 * is nameable. Measured on an iOS simulator, a `UIPickerView` row is three compact
 * lines — the cell, the label, and the cell's content view — of which two are
 * anonymous rectangles at the same place: 86 lines for a two-column wheel, 46 of
 * them carrying nothing an agent can act on. A caller reading that cannot tell
 * which of three lines is the row.
 *
 * A layer is folded when ALL of these hold, which is what makes it safe:
 *
 *  - it has no identity of its own — no id, label, text, region, char grid,
 *    scroll or wheel marker. The only reason it was kept is `isInteractive`;
 *  - a NAMED item's tap point falls inside it, so a tap aimed at the survivor
 *    still lands within this layer and still reaches whatever handler it carries;
 *  - it HUGS that item: at least as large, and no more than [WRAPPER_AREA_RATIO]×
 *    its area. A page-sized container that merely happens to contain a label is
 *    not a wrapper of it;
 *  - the two are related (ancestor, descendant, or siblings), so unrelated things
 *    that happen to overlap are never merged;
 *  - it is not a window or the application root — those are structure, named by
 *    the window header, and folding them on some screens but not others would be
 *    worse than either choice — and it does not hold input focus, which is a
 *    precise claim about one node that must not migrate.
 *
 * The survivor INHERITS `isInteractive`: the tappability was real and belonged to
 * that point on screen, and dropping it would turn a tappable row into a line that
 * reads inert. Nothing is lost from the snapshot — every folded node keeps its ref,
 * its frame and its properties there, reachable with `ui node --ref` — and the
 * count travels on the observation so the renderer can say the fold happened.
 */
private fun collapseWrappers(snapshot: Snapshot, items: List<CompactItem>): Folded {
    fun node(item: CompactItem) = snapshot.nodes[item.ref]
    fun identified(item: CompactItem): Boolean {
        val n = node(item) ?: return true // unknown node: never fold what we can't inspect
        return item.testId != null || item.resourceId != null || item.label != null ||
            item.scroll != null || item.wheel != null ||
            n.regions.isNotEmpty() || n.charGrid != null || n.suspectedMultiRegion ||
            // A DOM node's css selector is its handle, same as a testId. Read the
            // raw property here: the typed accessor lives in the helper.
            n.custom["domCssSelector"] != null
    }
    fun area(item: CompactItem): Double = item.frame?.let { it.width * it.height } ?: 0.0

    // Ancestor sets are memoized per ref: `related` runs once per
    // (anonymous, named) pair, and this function is on the wait poll's hot
    // path (every 100-250ms) — walking the parent chain with a fresh HashSet
    // per PAIR made a long recycling list cost millions of allocations per
    // poll. One walk per ref, O(1) membership per pair, same cycle guard.
    val ancestorSets = HashMap<String, Set<String>>()
    fun ancestorsOf(node: Node): Set<String> = ancestorSets.getOrPut(node.ref) {
        val out = HashSet<String>()
        var current = node.parentRef?.let { snapshot.nodes[it] }
        while (current != null && out.add(current.ref)) {
            current = current.parentRef?.let { snapshot.nodes[it] }
        }
        out
    }
    fun related(na: Node, nb: Node): Boolean {
        if (na.parentRef != null && na.parentRef == nb.parentRef) return true
        return nb.ref in ancestorsOf(na) || na.ref in ancestorsOf(nb)
    }

    // Named candidates with node, frame and area resolved ONCE — the anchor
    // scan re-derived all three per pair. Entries whose node is missing from
    // the snapshot are excluded up front: `related` could never hold for them
    // (order among the rest is preserved, so anchor choice is unchanged).
    class NamedEntry(val item: CompactItem, val node: Node, val frame: Rect, val area: Double)
    val named = items.mapNotNull { item ->
        if (!identified(item)) return@mapNotNull null
        val frame = item.frame ?: return@mapNotNull null
        val a = area(item)
        if (a <= 0.0) return@mapNotNull null
        val n = node(item) ?: return@mapNotNull null
        NamedEntry(item, n, frame, a)
    }
    if (named.isEmpty()) return Folded(items, 0)
    val absorbedInteractive = HashSet<String>()
    val dropped = HashSet<String>()
    for (item in items) {
        val n = node(item) ?: continue
        if (n.kind == NodeKind.window || n.kind == NodeKind.application) continue
        if (n.isFocused || identified(item)) continue
        val frame = item.frame ?: continue
        val self = area(item)
        if (self <= 0.0) continue
        val anchor = named.firstOrNull { other ->
            frame.contains(other.frame.centerX, other.frame.centerY) &&
                other.area <= self && self <= WRAPPER_AREA_RATIO * other.area &&
                related(n, other.node)
        } ?: continue
        dropped.add(item.ref)
        if (item.isInteractive) absorbedInteractive.add(anchor.item.ref)
    }
    if (dropped.isEmpty()) return Folded(items, 0)
    val kept = items.filterNot { it.ref in dropped }.map { item ->
        if (item.ref in absorbedInteractive && !item.isInteractive) item.copy(isInteractive = true) else item
    }
    return Folded(kept, dropped.size)
}

/** How much bigger than the node it wraps a layer may be and still be a wrapper. */
private const val WRAPPER_AREA_RATIO = 2.0

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
     * The in-app window this item belongs to, when it is inside one.
     *
     * A flat list of nodes from a stacked screen — a form pushed over a still-live
     * host page — interleaves the two windows by geometry, so the fields of the
     * screen being driven end up scattered among unrelated content. `occludedBy`
     * carries the same information only indirectly, and it is overloaded: it also
     * marks a node under the keyboard or under a popup in the SAME window, which
     * is a different situation with a different response.
     */
    val windowRef: String? = null,
    /**
     * True when this node holds input focus — where typed text will go. At most
     * one item in an observation carries it. Included because the compact view is
     * for acting NOW, and "which field is armed" is not inferable from a rect:
     * a compound widget's wrapper is `tappable` yet takes no focus, so a tap on it
     * arms nothing and `act type` would send text to whatever was focused before.
     */
    val isFocused: Boolean = false,
    /**
     * Toggle state when this item is a checkable control, null when it is not one.
     * Rendered as ` checked` / ` unchecked` / ` checked:mixed`.
     *
     * Null and `off` are different answers and the projection keeps them apart:
     * a consent row used to render identically before and after a tap ticked it,
     * so the only way to read the state was a screenshot.
     */
    val checked: CheckedState? = null,
    /**
     * Disclosure state when this item declares one, null when it does not.
     * Rendered as ` expanded` / ` collapsed`.
     *
     * The state that makes a dropdown drivable: a div-built select materialises
     * its options only once opened, so before the tap there is nothing to diff
     * against and this is the only evidence a tap did anything.
     */
    val expanded: Boolean? = null,
    /**
     * What kind of popup this item declares it opens (`aria-haspopup`), null
     * otherwise. Rendered as ` popup:<kind>`.
     *
     * The cue that an empty subtree is EXPECTED rather than a capture failure:
     * a control saying it opens a listbox has its options after a tap, not before.
     */
    val hasPopup: String? = null,
    /**
     * A DOM input's `placeholder`, when it has one. Rendered as
     * ` placeholder:"…"` — never merged into [label], because a placeholder is
     * what the field is ASKING for and [label] is what it HOLDS. Folding the two
     * together made an empty field and a filled one project identically.
     */
    val placeholder: String? = null,
    /**
     * A text field's accessible NAME, when it has one. Rendered as ` name:"…"`,
     * for the same reason [placeholder] is not merged into [label]: a field's name
     * is what it is FOR and [label] is what it HOLDS, and one slot cannot carry
     * both. Measured on a real form: with the name in the label slot, five filled
     * fields projected as their own names and nothing in the projection said what
     * any of them contained.
     */
    val name: String? = null,
    /**
     * Set when the field declares itself invalid (`aria-invalid`), carrying the
     * message its `aria-describedby` points at (empty string when it declares
     * invalidity with no message). Rendered as ` invalid` / ` invalid:"…"`.
     *
     * Without it a validation error is an ordinary sibling node and nothing says
     * which field it belongs to.
     */
    val invalid: String? = null,
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
     * Set when this web view's DOM walk stopped at the traversal's node cap,
     * carrying how many nodes it did capture. Rendered as ` dom:capped(N)`.
     *
     * Distinct from the projection cap in one way that matters: the nodes past
     * this one were never captured at all, so no `ui tree` or `ui node --ref` can
     * reach them. Narrow the page or scroll, rather than looking for them.
     */
    val domCappedAt: Long? = null,
    /**
     * True when this is a frame whose document is unreadable by browser policy.
     * Rendered as ` iframe:cross-origin`.
     *
     * The marker exists because the absence it explains is indistinguishable from
     * a frame that is still loading — so without it the honest answer ("nothing in
     * here is reachable; coordinates are the only path") reads as "try again".
     */
    val crossOriginFrame: Boolean = false,
    /**
     * Why this frame's subtree is empty, when the reason is NOT origin policy:
     * `"sandboxed"` (the page's own `sandbox` withheld same-origin access — a
     * same-site frame can land here, so calling it cross-origin sent readers
     * hunting a domain problem that was never there) or `"not-loaded"` (a `src`
     * is pending and the frame still answers with its placeholder document —
     * the one case where retrying IS the right move).
     *
     * Rendered as ` iframe:<reason>`. `"cross-origin"` keeps its own field above,
     * which agents already read, so exactly one marker ever appears.
     */
    val frameOpaque: String? = null,
    /**
     * True when a frame in this item's chain is rotated or skewed: [frame] is the
     * axis-aligned hull of the real box, so its centre is not guaranteed to be
     * inside the element. Rendered as ` geometry:approx` — a tap here may miss,
     * and that is worth one token rather than a silent 50/50.
     */
    val geometryApprox: Boolean = false,
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
        val labelPart = label?.let { " \"${it.clipCodePoints(40)}\"" } ?: ""
        val framePart = frame?.let {
            " [${it.x.toInt()},${it.y.toInt()} ${it.width.toInt()}x${it.height.toInt()}]"
        } ?: ""
        val state = buildString {
            if (!isEnabled) append(" disabled")
            if (isInteractive) append(" tappable")
            if (isFocused) append(" focused")
            when (checked) {
                CheckedState.on -> append(" checked")
                CheckedState.off -> append(" unchecked")
                CheckedState.mixed -> append(" checked:mixed")
                null -> Unit
            }
            when (expanded) {
                true -> append(" expanded")
                false -> append(" collapsed")
                null -> Unit
            }
            hasPopup?.let { append(" popup:").append(it) }
            name?.let { append(" name:\"${it.clipCodePoints(40)}\"") }
            placeholder?.let { append(" placeholder:\"${it.clipCodePoints(40)}\"") }
            invalid?.let {
                if (it.isEmpty()) append(" invalid") else append(" invalid:\"${it.clipCodePoints(40)}\"")
            }
            occludedBy?.let { append(" occluded-by:$it") }
            scroll?.describe()?.takeIf { it.isNotEmpty() }?.let { append(" ").append(it) }
            wheel?.let { append(" wheel:").append(it) }
            if (domUnavailable) append(" dom:unavailable")
            domCappedAt?.let { append(" dom:capped($it)") }
            if (crossOriginFrame) append(" iframe:cross-origin")
            else frameOpaque?.takeIf { it.isNotEmpty() }?.let { append(" iframe:").append(it) }
            if (geometryApprox) append(" geometry:approx")
            if (domKernelUnsupported) append(" dom:unsupported-kernel")
            if (pixelsUnavailable) append(" pixels:unavailable")
            if (screencapBlank) append(" screencap:blank")
        }
        return "$selector $role$labelPart$framePart$state"
    }
}
