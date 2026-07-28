package dev.reticle.cli

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
    fun isLoss(landed: Landed): Boolean = landed == Landed.PARTIAL || landed == Landed.NONE

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
        val frame = field.frame
        if (frame != null) {
            nodes.firstOrNull {
                isTextField(it) && it.frame?.let { f ->
                    f.x == frame.x && f.y == frame.y && f.width == frame.width
                } == true
            }?.let { return it }
        }
        return snapshot.nodes[field.ref]?.takeIf { it.typeName == field.typeName }
    }

    /** Does this node hold typed text as its own value? */
    private fun isTextField(node: Node): Boolean = when (node.kind) {
        NodeKind.view -> node.role == "textField" || node.typeName.endsWith("EditText")
        // Compose keeps a field's value in `EditableText`, which the bridge carries
        // as its own property precisely so a typed value is not confused with the
        // label `Text` holds on a Material `TextField`.
        NodeKind.composeSemantics -> node.custom.containsKey(EDITABLE_TEXT)
        else -> false
    }

    /**
     * The text this field holds — its VALUE, which on a Compose node is not the
     * same thing as `Node.text`.
     */
    fun valueOf(node: Node): String? =
        (node.custom[EDITABLE_TEXT] as? MetadataValue.Text)?.value ?: node.text

    private const val EDITABLE_TEXT = "editableText"

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
         * The DOM bridge emits `el.value || el.placeholder` as one `text`, so an
         * empty input is indistinguishable from one holding its placeholder text
         * and no before/after comparison over it can be trusted.
         */
        const val DOM_VALUE = "dom-input-value-not-separable-from-placeholder"
    }

    /**
     * Why [field] found nothing to read, said precisely. "No text field" and "a
     * text field this channel cannot read the value of" are different facts, and
     * only the second one names something a contributor could fix.
     */
    fun whyUnreadable(snapshot: Snapshot?, targetRef: String?): String {
        if (snapshot == null) return Unavailable.NO_RUNTIME
        val target = targetRef?.let { snapshot.nodes[it] } ?: return Unavailable.NO_FIELD
        return when (target.kind) {
            // A Compose node with no `EditableText`: either not a field at all, or a
            // Compose version too old for the property the bridge reads.
            NodeKind.composeSemantics -> Unavailable.COMPOSE_VALUE
            NodeKind.domNode -> Unavailable.DOM_VALUE
            else -> Unavailable.NO_FIELD
        }
    }
}
