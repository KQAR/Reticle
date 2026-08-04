package dev.reticle.core

/**
 * Matching a CSS selector against captured DOM nodes.
 *
 * `--css` used to be a string comparison against each node's captured
 * `domCssSelector` — the full ancestor path the traversal script emits. Only a
 * verbatim copy of that path could ever match, so the documented forms did not
 * work on a real page: `--css '#pay'` missed unless `#pay` happened to BE the
 * whole path, and `--css 'input.some-class'` missed on a page full of exactly
 * such inputs. Measured on a live form, and the miss then printed twelve
 * complete ancestor chains (~6 KB) of unrelated nodes as "candidates".
 *
 * What this does instead is match structurally, over the tree Reticle already
 * has: tag, id and classes per node, plus the parent chain. The supported
 * grammar is small and its limits are **refused rather than approximated** —
 * an unsupported construct throws [UnsupportedCssSelector] naming itself, so a
 * caller learns the selector was not understood instead of reading a miss as
 * "no such element".
 *
 * Supported:
 * - type: `div`, `input`
 * - id: `#pay`
 * - class: `.btn`, and compounds of the above: `input.form-control#email`
 * - descendant (` `) and child (` > `) combinators
 * - the ` >>> ` piercing chain, which is a descendant relationship in this tree:
 *   an open shadow root's children and a same-origin iframe's body are captured
 *   as children of the host node.
 * - `:nth-of-type(n)` and `:nth-child(n)`, the one pseudo-class family the
 *   captured paths themselves are built out of. Refusing it meant the only
 *   selector the tool EMITS was one the matcher accepted solely as a verbatim
 *   whole-string special case: trimming the path or aiming at the 2nd sibling
 *   instead of the 1st was rejected, so driving a form meant pasting a ~400-char
 *   path per interaction. The index is compared against the position the PAGE
 *   reported (`domNthOfType` / `domNthChild`), never against a count of captured
 *   siblings — the walk drops hidden elements, so counting here would answer
 *   `:nth-of-type(3)` with the third VISIBLE sibling and tap the wrong control.
 *
 * Refused, by name: attribute selectors, every other pseudo-class and every
 * pseudo-element, the universal selector, sibling combinators, and selector lists.
 *
 * The captured-path equality remains as a first attempt, so a path copied
 * verbatim out of a snapshot — colons and all — keeps working.
 */
object CssSelectorMatch {

    /**
     * The node [selector] names, or null.
     *
     * The single implementation of "what does `--css` mean", because there were
     * two: the resolver's and the helper's `findNode`, each doing its own exact
     * comparison against the captured path. Two copies of a rule is how the two
     * drift, and this one had already drifted from what the docs promised.
     *
     * Exact captured-path equality first — a path copied verbatim out of a
     * snapshot, `:nth-of-type` and all, is a legitimate way to name a node and
     * costs one string compare. Then the structural match, which is what a caller
     * would actually type.
     *
     * Document order, not map order: a `Map`'s iteration order is a decoding
     * detail, and on the Swift side a `Dictionary`'s is hash-seeded per process.
     *
     * @throws UnsupportedCssSelector for syntax this matcher does not implement.
     */
    fun find(snapshot: Snapshot, selector: String): Node? {
        snapshot.firstNode { it.domCssSelector() == selector }?.let { return it }
        // Parse once, up front: an unsupported construct must surface as a refusal
        // rather than as an empty result, and doing it here means every call site
        // gets that behaviour without having to remember to ask for it.
        val steps = parse(selector)
        assertPositionsAreCaptured(snapshot, selector, steps)
        return snapshot.firstNode {
            it.kind == NodeKind.domNode && matches(snapshot, it, selector)
        }
    }

    /** A compound selector: at most one tag and id, any number of classes. */
    private data class Compound(
        val tag: String? = null,
        val id: String? = null,
        val classes: List<String> = emptyList(),
        val nthOfType: Int? = null,
        val nthChild: Int? = null,
    ) {
        fun matches(node: Node): Boolean {
            tag?.let { if (!node.domTag().equals(it, ignoreCase = true)) return false }
            id?.let { if (node.domId() != it) return false }
            if (classes.isNotEmpty()) {
                val own = node.domClasses()
                if (!own.containsAll(classes)) return false
            }
            // A node with no captured position cannot satisfy a positional query.
            // Reported as a refusal rather than a miss when NOTHING on the screen
            // carries one — see [assertPositionsAreCaptured].
            nthOfType?.let { if (node.domNthOfType() != it) return false }
            nthChild?.let { if (node.domNthChild() != it) return false }
            return true
        }

        val isPositional: Boolean get() = nthOfType != null || nthChild != null
    }

    /** How a compound relates to the one before it. */
    private enum class Combinator { DESCENDANT, CHILD }

    private data class Step(val combinator: Combinator, val compound: Compound)

    /**
     * Does [node] match [selector] within [snapshot]?
     *
     * @throws UnsupportedCssSelector when the selector uses a construct this
     * matcher does not implement. Never returns false for that case: "not
     * understood" and "no such element" are different answers.
     */
    fun matches(snapshot: Snapshot, node: Node, selector: String): Boolean {
        val steps = parse(selector)
        val subject = steps.last()
        if (!subject.compound.matches(node)) return false
        return matchesAncestors(snapshot, node, steps.dropLast(1))
    }

    /**
     * True when [selector] is structurally parseable. Callers that want to fall
     * back rather than fail use this to tell "unsupported syntax" from "no match",
     * which are different things to report.
     */
    fun isSupported(selector: String): Boolean =
        runCatching { parse(selector) }.isSuccess

    /**
     * Walk the remaining steps right-to-left over [node]'s ancestors.
     *
     * Descendant steps backtrack (any ancestor may satisfy them), which is why
     * this recurses rather than looping: a failure further up must be able to try
     * the next candidate ancestor.
     */
    private fun matchesAncestors(snapshot: Snapshot, node: Node, steps: List<Step>): Boolean {
        if (steps.isEmpty()) return true
        val step = steps.last()
        val rest = steps.dropLast(1)
        var current = node.parentRef?.let { snapshot.nodes[it] }
        val seen = HashSet<String>()
        while (current != null && seen.add(current.ref)) {
            if (step.compound.matches(current) && matchesAncestors(snapshot, current, rest)) return true
            // A child combinator gets exactly one shot: the immediate parent.
            if (step.combinator == Combinator.CHILD) return false
            current = current.parentRef?.let { snapshot.nodes[it] }
        }
        return false
    }

    private fun parse(selector: String): List<Step> {
        val trimmed = selector.trim()
        if (trimmed.isEmpty()) throw UnsupportedCssSelector(selector, "an empty selector")
        // ` >>> ` pierces a shadow root or a same-origin iframe. In THIS tree that
        // is an ordinary ancestor relationship — pierced content is captured as
        // children of the host — so it reduces to a descendant combinator.
        val normalized = trimmed.replace(" >>> ", " ")
        // Pseudo-classes first, and by name: `:nth-of-type(2)` is supported while
        // `:hover` is not, so a blanket "contains a colon" refusal cannot tell them
        // apart. The char-level checks below then run on the selector with the
        // pseudo parts removed, so their parens and digits trip nothing.
        validatePseudos(selector, normalized)
        rejectUnsupported(selector, normalized.replace(PSEUDO, ""))
        val tokens = tokenize(normalized, selector)
        if (tokens.isEmpty()) throw UnsupportedCssSelector(selector, "no compound selectors")
        return tokens
    }

    /**
     * A positional query against a capture that has no positions in it is an
     * agent/host version skew, not "no such element" — say so instead of missing.
     * Only fires when NOTHING on the screen carries a position: one node without
     * one, on a screen where others have them, genuinely is not at that index.
     */
    private fun assertPositionsAreCaptured(snapshot: Snapshot, selector: String, steps: List<Step>) {
        if (steps.none { it.compound.isPositional }) return
        val domNodes = snapshot.nodes.values.filter { it.kind == NodeKind.domNode }
        if (domNodes.isEmpty()) return
        if (domNodes.any { it.domNthOfType() != null || it.domNthChild() != null }) return
        throw UnsupportedCssSelector(
            selector,
            "a positional pseudo-class this capture cannot answer: none of its " +
                "${domNodes.size} DOM node(s) carry a sibling position, which means the app's " +
                "Reticle agent predates it — re-capture with a matching agent, or drop the " +
                "`:nth-…()` part",
        )
    }

    private fun rejectUnsupported(original: String, normalized: String) {
        val constructs = listOf(
            '[' to "attribute selectors",
            '*' to "the universal selector",
            '+' to "the adjacent-sibling combinator",
            '~' to "the general-sibling combinator",
            ',' to "selector lists",
        )
        for ((char, name) in constructs) {
            if (normalized.contains(char)) throw UnsupportedCssSelector(original, name)
        }
    }

    /** Every `:pseudo` / `:pseudo(arg)` in a selector. */
    private val PSEUDO = Regex(":([A-Za-z-]+)(?:\\(([^)]*)\\))?")

    /**
     * Accept the two positional pseudo-classes the captured paths are built out of,
     * and refuse every other one BY NAME. `:nth-of-type(2n+1)` is refused as its own
     * thing rather than as "a sibling combinator", which is what the old character
     * scan would have called the `+`.
     */
    private fun validatePseudos(original: String, normalized: String) {
        for (match in PSEUDO.findAll(normalized)) {
            val name = match.groupValues[1].lowercase()
            val arg = match.groupValues[2]
            if (name != "nth-of-type" && name != "nth-child") {
                throw UnsupportedCssSelector(original, "the pseudo-class or pseudo-element ':$name'")
            }
            val index = arg.trim().toIntOrNull()
            if (index == null || index < 1) {
                throw UnsupportedCssSelector(
                    original,
                    "':$name($arg)' rather than a plain 1-based index — an an+b expression or a " +
                        "keyword argument is not implemented, only `:$name(2)`",
                )
            }
        }
    }

    private fun tokenize(normalized: String, original: String): List<Step> {
        val steps = ArrayList<Step>()
        var combinator = Combinator.DESCENDANT
        // Split on whitespace, treating a bare `>` as the combinator for the next
        // compound. `a>b` without spaces is handled by padding first.
        val padded = normalized.replace(">", " > ")
        for (token in padded.split(' ', '\t', '\n').filter { it.isNotBlank() }) {
            if (token == ">") {
                combinator = Combinator.CHILD
                continue
            }
            steps.add(Step(combinator, compound(token, original)))
            combinator = Combinator.DESCENDANT
        }
        return steps
    }

    private fun compound(token: String, original: String): Compound {
        var nthOfType: Int? = null
        var nthChild: Int? = null
        // The pseudo parts were validated in `validatePseudos`; pull their indices out
        // and parse what is left as the plain tag/id/class compound it now is.
        val bare = PSEUDO.replace(token) { match ->
            val index = match.groupValues[2].trim().toIntOrNull()
            when (match.groupValues[1].lowercase()) {
                "nth-of-type" -> nthOfType = index
                "nth-child" -> nthChild = index
                else -> throw UnsupportedCssSelector(original, "the pseudo-class ':${match.groupValues[1]}'")
            }
            ""
        }
        var tag: String? = null
        var id: String? = null
        val classes = ArrayList<String>()
        var index = 0
        val name = StringBuilder()
        var kind = ' '
        fun flush() {
            if (name.isEmpty()) return
            when (kind) {
                '#' -> id = name.toString()
                '.' -> classes.add(name.toString())
                else -> tag = name.toString()
            }
            name.clear()
        }
        while (index < bare.length) {
            val ch = bare[index]
            if (ch == '#' || ch == '.') {
                flush()
                kind = ch
            } else {
                name.append(ch)
            }
            index++
        }
        flush()
        return Compound(tag, id, classes, nthOfType, nthChild)
    }
}

/**
 * A CSS selector using a construct [CssSelectorMatch] does not implement.
 *
 * Thrown rather than answered `false` on purpose. A matcher that silently
 * declines to understand `:hover` reports the same thing as one that looked and
 * found nothing, and only one of those means "this element is not on screen".
 */
class UnsupportedCssSelector(val selector: String, val construct: String) : IllegalArgumentException(
    "css selector '$selector' uses $construct, which Reticle's matcher does not implement. " +
        "Supported: type, #id, .class and their compounds, with descendant / child (>) / pierce (>>>) " +
        "combinators, plus :nth-of-type(n) / :nth-child(n). A full path copied verbatim out of a " +
        "snapshot also still matches exactly.",
)
