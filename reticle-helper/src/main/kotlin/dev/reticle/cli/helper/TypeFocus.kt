package dev.reticle.cli

import dev.reticle.core.Node
import dev.reticle.core.NodeKind
import dev.reticle.core.Snapshot

/**
 * Where the focus actually went after `act type` tapped its target field.
 *
 * `type`'s contract is "give it a selector and the text lands in THAT field", and
 * the only thing that made it true was a tap on the resolved rect. That is not
 * enough for the commonest shape of app-owned compound widget: an outer container
 * carries the stable, unique test id and the real `EditText` is nested inside it
 * with a generic id repeated across the page. The container is then the only
 * addressable handle — and tapping it moves focus nowhere, so `adb input text`
 * goes to whatever held focus before, which is usually nothing. Measured on a
 * physical device: `chars=4 focusedVia=semantic:testId`, exit code 0, and the
 * field stayed empty; the only hint was `0 change(s)` in the trace line, two
 * fields later.
 *
 * `type` has a cheap, unambiguous post-condition that a generic tap does not, so
 * it checks it: after the focusing tap, read the tree back and see who holds
 * focus. Note what CANNOT serve here — `keyboardVisible` was 0 in the WORKING case
 * too, because the device's IME renders no window.
 */
internal object TypeFocus {

    /** Where focus landed, relative to the node the selector resolved to. */
    enum class Landing {
        /** The resolved node itself took focus. The plain success. */
        SELF,

        /** A node inside it did — the compound widget worked as intended. */
        DESCENDANT,

        /**
         * A node ABOVE it holds focus. Not a failure: a WebView owns the platform
         * focus while the caret is in a DOM input, and an `AndroidComposeView` owns
         * it while a Compose `TextField` is focused. Neither has a per-node focus
         * channel of its own, so an ancestor is as precise as this can get.
         */
        ANCESTOR,

        /** Some unrelated node holds focus — the text is about to land in it. */
        ELSEWHERE,

        /**
         * The target's ref is not in the capture the focus was read from, so this
         * reading cannot say where focus went relative to it.
         *
         * A ref is the traversal INDEX of a node in the capture it came from, and a
         * relayout — in a WebView, any re-render — renumbers the whole tree. The
         * focusing tap can cause one itself by scrolling the field into view. The
         * distinction matters because the old answer for this was [ELSEWHERE],
         * which asserts something false and actionable ("the text is about to land
         * in a different field") about a capture that simply cannot be compared.
         */
        TARGET_GONE,

        /** Nothing in the tree holds focus — the text is about to land nowhere. */
        NONE,

        /** No focus reading available (runtime unreachable, or an older agent). */
        UNKNOWN,
    }

    /** Wire spelling for the `focusLanded=` field. */
    fun label(landing: Landing): String = landing.name.lowercase()

    /** True when the text can be expected to reach the field the caller named. */
    fun isLanded(landing: Landing): Boolean =
        landing == Landing.SELF || landing == Landing.DESCENDANT ||
            landing == Landing.ANCESTOR || landing == Landing.UNKNOWN

    /**
     * Classify the focus in [snapshot] against [targetRef] (null for a raw
     * `--point`, where there is no node to be related to — only "someone has
     * focus" or "nobody does" is knowable).
     *
     * Focus is read across ALL windows rather than one: a dialog or popup holds
     * focus while the activity's base window does not, and `isFocused` is a
     * per-hierarchy flag, so several windows can each report one.
     */
    fun classify(snapshot: Snapshot, targetRef: String?): Landing {
        val focused = snapshot.nodes.values.filter { it.isFocused }
        if (focused.isEmpty()) return Landing.NONE
        if (targetRef == null) return Landing.UNKNOWN
        // Not in this capture at all: refs were renumbered under us, so no relation
        // to the focused node can be computed — see [Landing.TARGET_GONE].
        if (snapshot.nodes[targetRef] == null) return Landing.TARGET_GONE
        if (focused.any { it.ref == targetRef }) return Landing.SELF
        if (focused.any { isDescendantOf(snapshot, it, targetRef) }) return Landing.DESCENDANT
        val target = snapshot.nodes[targetRef]
        if (target != null && focused.any { isDescendantOf(snapshot, target, it.ref) }) return Landing.ANCESTOR
        return Landing.ELSEWHERE
    }

    /**
     * The one focusable text input inside [targetRef], when there is exactly one.
     *
     * The retarget candidate for the compound-widget case: unique id on the
     * wrapper, generic id on the real input. Exactly one is the whole condition —
     * with two, picking either would be a guess, and this file refuses to guess
     * for the same reason `--label` refuses an ambiguous match.
     */
    fun soleFocusableInput(snapshot: Snapshot, targetRef: String): Node? {
        val target = snapshot.nodes[targetRef] ?: return null
        val candidates = ArrayList<Node>(2)
        fun visit(ref: String) {
            val node = snapshot.nodes[ref] ?: return
            if (ref != targetRef && node.isVisible && node.isFocusable && isTextInput(node)) {
                candidates.add(node)
                // Don't descend into an input's own children: an EditText has none
                // that matter, and a nested one would make a single field read as two.
                return
            }
            node.children.forEach(::visit)
        }
        visit(target.ref)
        return candidates.singleOrNull()
    }

    /** Does this node accept typed text, as opposed to merely taking focus? */
    private fun isTextInput(node: Node): Boolean =
        node.kind == NodeKind.view &&
            (node.role == "textField" || node.typeName.endsWith("EditText"))

    private fun isDescendantOf(snapshot: Snapshot, node: Node, ancestorRef: String): Boolean {
        var current = node.parentRef?.let { snapshot.nodes[it] }
        val seen = HashSet<String>()
        while (current != null && seen.add(current.ref)) {
            if (current.ref == ancestorRef) return true
            current = current.parentRef?.let { snapshot.nodes[it] }
        }
        return false
    }

    /**
     * The refusal message for text that would land in the wrong place. Names the
     * retarget candidate when there is one, because "the container is not the
     * field" is only half of what the caller needs.
     */
    fun refusal(landing: Landing, target: ResolvedInputTarget, candidate: Node?): String = buildString {
        append("resolved '${target.source}' -> ${target.ref ?: "point"} but the tap did not focus a text field ")
        append(
            when (landing) {
                Landing.NONE -> "(nothing in the app holds input focus)"
                Landing.TARGET_GONE ->
                    "(that ref is not in the tree read back after the tap — a relayout, or in a " +
                        "WebView a re-render, renumbered it, so where focus went cannot be judged " +
                        "against it)"
                else -> "(focus is on an unrelated node)"
            }
        )
        append(". Typing now would send the text ")
        append(
            when (landing) {
                Landing.NONE -> "nowhere"
                Landing.TARGET_GONE -> "somewhere this cannot confirm"
                else -> "into whatever holds focus"
            }
        )
        append(" while reporting success, so it is refused.\n")
        if (landing == Landing.TARGET_GONE) {
            append("  Address the field by a handle that survives a re-render — `--css` for a DOM ")
            append("node, `--test-id` / `--resource-id` for a native one — rather than by `--ref`.\n")
        }
        if (candidate != null) {
            val handle = candidate.testId?.let { "--test-id $it" }
                ?: candidate.resourceId?.let { "--resource-id $it" }
                ?: "--ref ${candidate.ref}"
            append("  Reticle re-aimed at the one focusable input inside it ($handle) and focus still did not land.\n")
        }
        append("  A wrapper carrying the test id with the real input nested inside is the usual cause; ")
        append("target the input itself (`ui node --ref ${target.ref ?: "…"}` shows its children), ")
        append("or use --point on the field.")
    }
}
