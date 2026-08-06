package dev.reticle.cli

import dev.reticle.core.CssSelectorMatch
import dev.reticle.core.MetadataValue
import dev.reticle.core.Node
import dev.reticle.core.NodeKind
import dev.reticle.core.Snapshot

/**
 * What actually reached the field after `act type` dispatched its text.
 *
 * [TypeFocus] closed the question "is the caret in the right box"; this closes the
 * one after it: "did the characters get there". `chars=N` only ever meant N were
 * SENT. The measured failure is a five-character `--text "10000"` that left `100`
 * in the field, exit code 0, `chars=5`, focus correct — the same command into the
 * neighbouring field on the same screen landing all five. The difference is what
 * the field does on each keystroke: the lossy one reformats its value in a
 * `TextWatcher` and drives a re-render of a widget at the top of the page (101
 * changes in the trace against the other's 6), and `adb shell input text` delivers
 * the characters as a burst that a re-layout in the middle of it can eat.
 *
 * So `type` reads the field back and reports the text it finds, rather than the
 * text it sent. Everything here is evidence: [Landed] classifies the pair
 * (before, after) against what was typed, and a case that cannot be classified
 * says [Landed.UNREADABLE] instead of assuming success.
 *
 * Deliberately NOT a pass/fail verdict. An app is free to transform what it is
 * given — uppercasing, inserting thousands separators, truncating at `maxLength` —
 * and none of those are Reticle's to call wrong. [Landed.CHANGED] is that case,
 * kept apart from [Landed.PARTIAL] (a proper prefix of the typed text and nothing
 * else) precisely because only the latter is the burst-loss shape.
 */
internal object TypeReadback {

    /** How the field's text after typing relates to the text that was sent. */
    enum class Landed {
        /** The typed text is in the field, verbatim. */
        EXACT,

        /**
         * The field holds the typed characters plus formatting the app added
         * (`10000` -> `10,000`). Everything sent is there; the app dressed it.
         */
        REFORMATTED,

        /** A proper, non-empty PREFIX of the typed text. The burst-loss shape. */
        PARTIAL,

        /**
         * Every character in the field came from the typed text, in order, but some
         * are MISSING from the middle or the end — characters were dropped, not
         * transformed.
         *
         * Measured on a masked postcode field: `--text "12-345"` left `12-45`, one
         * digit short. That is not a prefix (the tail `0` arrived), so it used to
         * classify as [CHANGED] — "the app transformed its input, not a defect" —
         * and a lost digit went out under the same label as an uppercasing. The
         * mask inserts its own separator on each keystroke, and a burst can lose a
         * character anywhere in it, not only off the end.
         */
        DROPPED,

        /** The field's text did not change at all. Nothing landed. */
        NONE,

        /**
         * The text changed, but not into anything derivable from what was sent —
         * an app transforming its input (masking, uppercasing, `maxLength`), which
         * is the app's business, not a defect. Reported, never retried.
         */
        CHANGED,

        /** No text channel on the field (or no read-back at all). Not a claim. */
        UNREADABLE,
    }

    /** Wire spelling for the `textLanded=` field. */
    fun label(landed: Landed): String = landed.name.lowercase()

    /** Classification plus, for [Landed.PARTIAL], how many characters made it. */
    data class Verdict(val landed: Landed, val landedChars: Int)

    /**
     * Only these two are the burst-loss shape, and only these two are worth
     * re-sending through the atomic clipboard path. [Landed.CHANGED] is the app
     * doing its job, and re-typing over it would fight the app.
     */
    fun isLoss(landed: Landed): Boolean =
        landed == Landed.PARTIAL || landed == Landed.NONE || landed == Landed.DROPPED

    /**
     * Compare the field's text [before] and [after] typing [typed].
     *
     * `type` inserts at the caret rather than replacing, so "the typed text is in
     * there" is a containment question, not an equality one; the length delta is
     * what separates "all of it arrived" from "some of it did".
     */
    fun classify(before: String, after: String, typed: String): Verdict {
        if (typed.isEmpty()) return Verdict(Landed.EXACT, 0)
        if (after == before) return Verdict(Landed.NONE, 0)
        val gained = after.length - before.length
        if (gained == typed.length && after.contains(typed)) {
            return Verdict(Landed.EXACT, typed.length)
        }
        if (isReformatOf(before, after, typed)) {
            return Verdict(Landed.REFORMATTED, typed.length)
        }
        // A proper prefix and nothing more is the signature of a burst cut short:
        // the characters arrive in order, and the ones that were dropped are the
        // tail. A field that rewrote what it was given does not look like this.
        val prefix = longestLandedPrefix(before, after, typed)
        if (prefix in 1 until typed.length) return Verdict(Landed.PARTIAL, prefix)
        val dropped = droppedChars(before, after, typed)
        if (dropped > 0) return Verdict(Landed.DROPPED, core(after).length)
        return Verdict(Landed.CHANGED, 0)
    }

    /**
     * Is [after] the app's own formatting of an insertion that fully landed? Judged
     * on the alphanumeric projection, because a formatter's whole job is to add the
     * characters that are not — separators, spaces, punctuation.
     */
    private fun isReformatOf(before: String, after: String, typed: String): Boolean {
        val typedCore = core(typed)
        if (typedCore.isEmpty()) return false
        val beforeCore = core(before)
        val afterCore = core(after)
        return afterCore.length == beforeCore.length + typedCore.length &&
            afterCore.contains(typedCore)
    }

    /**
     * How many typed characters are missing when everything in the field DID come
     * from the typed text, in order — see [Landed.DROPPED]. Zero when that is not
     * the shape.
     *
     * Only judged for a field that was EMPTY before, where all of the value has to
     * have come from the insertion. With pre-existing content the insertion point
     * is unknown, and calling a transformed value "dropped" would be a guess — that
     * case stays [Landed.CHANGED], which claims nothing.
     *
     * Case-sensitive on purpose: an app that uppercases what it is given rewrites
     * its input rather than losing any of it, and must not read as loss.
     */
    private fun droppedChars(before: String, after: String, typed: String): Int {
        if (core(before).isNotEmpty()) return 0
        val typedCore = core(typed)
        val afterCore = core(after)
        if (afterCore.isEmpty() || afterCore.length >= typedCore.length) return 0
        return if (isSubsequence(afterCore, typedCore)) typedCore.length - afterCore.length else 0
    }

    /** Is [inner] a subsequence of [outer]? */
    private fun isSubsequence(inner: String, outer: String): Boolean {
        var i = 0
        for (c in outer) {
            if (i < inner.length && inner[i] == c) i++
        }
        return i == inner.length
    }

    /** The longest prefix of [typed] that the insertion accounts for. */
    private fun longestLandedPrefix(before: String, after: String, typed: String): Int {
        val beforeCore = core(before)
        val afterCore = core(after)
        for (n in typed.length - 1 downTo 1) {
            val prefixCore = core(typed.substring(0, n))
            if (prefixCore.isEmpty()) continue
            if (afterCore.length == beforeCore.length + prefixCore.length &&
                afterCore.contains(prefixCore)
            ) {
                return n
            }
        }
        return 0
    }

    /** Letters and digits only — what survives an app's own formatting. */
    private fun core(value: String): String = value.filter { it.isLetterOrDigit() }

    /**
     * The node whose text answers "did it land": the field the characters go to.
     *
     * Focus first, because focus is where `input text` delivers regardless of what
     * the caller named. Falls back to the resolved target (or the one input inside
     * it) for the platforms with no per-node focus channel — a Compose `TextField`
     * or a DOM input leaves the platform focus on the host view, whose text is not
     * the field's.
     */
    fun field(snapshot: Snapshot, targetRef: String?): Node? {
        snapshot.nodes.values.firstOrNull { it.isFocused && isTextField(it) }?.let { return it }
        val target = targetRef?.let { snapshot.nodes[it] } ?: return null
        if (isTextField(target)) return target
        return TypeFocus.soleFocusableInput(snapshot, target.ref)
            // A DOM wrapper the caller resolved instead of the input inside it: a
            // `<div>` that carries the class, with the `<input>` one level down. The
            // native path above cannot see it — its `isTextInput` is typed on view
            // nodes — so the read-back reported `dom-node-is-not-a-text-input` for
            // text that plainly landed. Measured on a real form, with `ui compact`
            // showing the value in the field at the same moment.
            ?: soleDomInput(snapshot, target.ref)
    }

    /**
     * The one DOM text input under [targetRef], preferring the focused one.
     *
     * Exactly one, for the same reason [TypeFocus.soleFocusableInput] insists on it:
     * with two, picking either is a guess. A focused descendant settles it though —
     * that is where the caret is, so it is not a guess at all.
     */
    private fun soleDomInput(snapshot: Snapshot, targetRef: String): Node? {
        val found = ArrayList<Node>(2)
        fun visit(ref: String) {
            val node = snapshot.nodes[ref] ?: return
            if (ref != targetRef && node.kind == NodeKind.domNode && isTextField(node)) {
                found.add(node)
                return
            }
            node.children.forEach(::visit)
        }
        visit(targetRef)
        return found.firstOrNull { it.isFocused } ?: found.singleOrNull()
    }

    /**
     * Re-find [field] in a later snapshot. Refs are traversal indices, so a typing
     * re-layout can renumber the tree — the very re-layout this check exists for.
     * Identity is the node's own stable handles, and position is the last resort
     * rather than the first, since a re-layout moves rects too.
     */
    fun refind(snapshot: Snapshot, field: Node): Node? {
        val nodes = snapshot.nodes.values
        field.testId?.let { id ->
            nodes.filter { it.testId == id }.singleOrNull()?.let { return it }
        }
        field.resourceId?.let { id ->
            nodes.filter { it.resourceId == id }.singleOrNull()?.let { return it }
        }
        // A DOM node's handle that survives a re-render. Without this the fallbacks
        // below decide it, and both are wrong for the DOM: the frame moves when the
        // page scrolls (which typing itself causes), and EVERY DOM node's typeName is
        // `DOMElement`, so the ref fallback's typeName check proves nothing and a
        // renumbered ref reads a STRANGER's text. Measured on a real form: `--clear`
        // refused three times citing 6, 9 and 18 characters while the field it named
        // was empty in the same screenshot — the lengths belonged to whatever div had
        // inherited those refs.
        field.domCssSelector()?.let { css ->
            CssSelectorMatch.find(snapshot, css)?.let { return it }
        }
        // The field's accessible NAME, when it has one and it is unique among text
        // fields. A framework form's inputs carry no id and their captured css path
        // runs through `:nth-of-type(n)` wrappers that a validation row appearing
        // above the field renumbers — the name is what stays put across exactly the
        // re-render that typing and clearing provoke.
        field.contentDescription?.takeIf { it.isNotEmpty() }?.let { name ->
            nodes.filter { isTextField(it) && it.contentDescription == name }
                .singleOrNull()?.let { return it }
        }
        val frame = field.frame
        if (frame != null) {
            nodes.firstOrNull {
                isTextField(it) && it.frame?.let { f ->
                    f.x == frame.x && f.y == frame.y && f.width == frame.width
                } == true
            }?.let { return it }
        }
        // The ref fallback is only evidence when typeName distinguishes something.
        // It does not in the DOM, so a DOM field that could not be re-found by
        // selector or rect is reported as GONE rather than as a stranger's value.
        if (field.kind == NodeKind.domNode) return null
        return snapshot.nodes[field.ref]?.takeIf { it.typeName == field.typeName }
    }

    /** Does this node hold typed text as its own value? */
    private fun isTextField(node: Node): Boolean = when (node.kind) {
        NodeKind.view -> node.role == "textField" || node.typeName.endsWith("EditText")
        // Compose keeps a field's value in `EditableText`, which the bridge carries
        // as its own property precisely so a typed value is not confused with the
        // label `Text` holds on a Material `TextField`.
        NodeKind.composeSemantics -> node.custom.containsKey(EDITABLE_TEXT)
        // A DOM input's `text` IS its value now. It used to be `value || placeholder`
        // as one string, which made an empty field indistinguishable from one showing
        // its placeholder — so no before/after comparison over it could be trusted and
        // this branch returned false, i.e. every web form was structurally unreadable.
        // The two are separate fields since the DOM input-semantics change, so the
        // comparison is sound and the read-back applies here like anywhere else.
        NodeKind.domNode -> node.role == "textField"
        else -> false
    }

    /**
     * The text this field holds — its VALUE, which on a Compose node is not the
     * same thing as `Node.text`.
     */
    fun valueOf(node: Node): String? {
        (node.custom[EDITABLE_TEXT] as? MetadataValue.Text)?.value?.let { return it }
        node.text?.let { return it }
        // An EMPTY DOM input carries no `text` at all, and "" and null are different
        // claims: one is "the field holds nothing", the other is "there is no text
        // channel here". Conflating them made `--clear` on an empty field refuse with
        // `field-exposes-no-text` — a missing check reported as a failed one — and it
        // is exactly the distinction the DOM input-semantics change was made to keep.
        if (node.kind == NodeKind.domNode && node.role == "textField") return ""
        return null
    }

    private const val EDITABLE_TEXT = "editableText"

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
     * Why a read-back could not be made, in the caller's terms. An absent check is
     * reported as absent — the one thing this must never do is look like a pass.
     */
    object Unavailable {
        const val NO_RUNTIME = "runtime-unreachable"
        const val NO_FIELD = "no-text-field-node"
        const val NO_TEXT_CHANNEL = "field-exposes-no-text"
        const val GONE = "field-not-in-tree-after-typing"

        /**
         * A Compose text field keeps its value in `SemanticsProperties.EditableText`,
         * which the Compose bridge does not read (it reads `Text`, the label). Not a
         * platform wall — a gap named as one, so it reads as work to do rather than
         * as a landing.
         */
        const val COMPOSE_VALUE = "compose-field-value-not-captured"

        /**
         * A DOM element the caller aimed at that is not a text input — a `<button>`,
         * a checkbox, a wrapper `<div>`. There is no value to compare.
         *
         * Note what this is NOT: it used to be `dom-input-value-not-separable-from-
         * placeholder`, which applied to EVERY DOM node because the bridge emitted
         * `value || placeholder` as one string. That was a real wall while it lasted
         * and it made every web form unreadable; it is gone, and so is the reason.
         */
        const val DOM_NOT_INPUT = "dom-node-is-not-a-text-input"
    }

    /**
     * Why [field] found nothing to read, said precisely. "No text field" and "a
     * text field this channel cannot read the value of" are different facts, and
     * only the second one names something a contributor could fix.
     */
    fun whyUnreadable(snapshot: Snapshot?, targetRef: String?): String {
        if (snapshot == null) return Unavailable.NO_RUNTIME
        val target = targetRef?.let { snapshot.nodes[it] } ?: return Unavailable.NO_FIELD
        // Two different nodes are involved when the caller resolved a wrapper, and
        // the old message named neither: it said "dom-node-is-not-a-text-input"
        // about the RESOLVED node while `ui compact` for the same region plainly
        // showed a `textField`. Say which node was inspected, and where the caret is.
        if (target.kind == NodeKind.domNode) {
            val focused = snapshot.nodes.values.firstOrNull { it.isFocused && isTextField(it) }
            if (focused != null) {
                return "${Unavailable.DOM_NOT_INPUT} (${target.ref}); the caret is in ${focused.ref}, " +
                    "which was not the node this read looked at"
            }
            val inputs = snapshot.nodes.values.count {
                it.kind == NodeKind.domNode && isTextField(it) && isDescendantOf(snapshot, it, target.ref)
            }
            if (inputs > 1) {
                return "${Unavailable.DOM_NOT_INPUT} (${target.ref} is a wrapper around $inputs text " +
                    "inputs, and none of them holds the caret — aim at one of them)"
            }
        }
        return when (target.kind) {
            // A Compose node with no `EditableText`: either not a field at all, or a
            // Compose version too old for the property the bridge reads.
            NodeKind.composeSemantics -> Unavailable.COMPOSE_VALUE
            NodeKind.domNode -> Unavailable.DOM_NOT_INPUT
            else -> Unavailable.NO_FIELD
        }
    }
}
