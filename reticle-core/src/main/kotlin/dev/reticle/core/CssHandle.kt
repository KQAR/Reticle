package dev.reticle.core

/**
 * The shortest `--css` that still names ONE node of this capture.
 *
 * The traversal emits each DOM element's full ancestor path, because that is the
 * one form guaranteed to be unambiguous. Printing it is a different question, and
 * the answer was measured: on a real hybrid form every
 * `ui outline` line carried a ~400-character path, and one screen cost **17.8 KB**
 * against 5.9 KB for the same screen's `ui compact` — the view sold as the cheap
 * ad-hoc loop was the most expensive thing to read, by 3x, exactly where a hybrid
 * app needs it most.
 *
 * Almost all of that is lineage the reader never asked for
 * (`body:nth-of-type(1) > div:nth-of-type(1) > div.full-flow:nth-of-type(1) > …`).
 * A path is only needed as far back as it takes to be unique, so:
 *
 *  1. `#id`, when the element has one and no other captured node repeats it;
 *  2. the shortest **suffix** of the captured path that ends at a segment boundary
 *     and matches exactly one captured node — `input.ep-form-base-input__control`,
 *     or `div.form-row:nth-of-type(3) > … > input` when the tail alone repeats;
 *  3. the full path, unchanged, when even that is not unique (identical siblings
 *     under identical parents). Never a shorter form that would resolve to a
 *     different node than the one being described.
 *
 * Uniqueness is decided against the paths in THIS capture, which is the same set
 * `--css` will be matched against, and a suffix of a path is exactly what the
 * descendant/child combinators the matcher implements will re-resolve. Two things
 * follow that a caller should know: the handle is honest about the capture, not
 * about the page (a node the walk never reached cannot make it ambiguous), and it
 * is stable across a re-render in the same way the path it came from is.
 */
object CssHandle {
    private const val CHILD = " > "

    /**
     * A per-snapshot index, so a projection that shortens 200 handles walks the
     * node set once rather than once per handle.
     */
    class Index(snapshot: Snapshot) {
        private val paths: List<String> = snapshot.nodes.values.mapNotNull { it.domCssSelector() }
        private val idCounts: Map<String, Int> = snapshot.nodes.values
            .mapNotNull { it.domId()?.takeIf { id -> id.isNotBlank() } }
            .groupingBy { it }
            .eachCount()

        /**
         * Whether this capture can answer a `:nth-…()` at all.
         *
         * The matcher checks a positional pseudo-class against the position the PAGE
         * reported (`domNthOfType` / `domNthChild`), so a capture from an agent that
         * predates those fields cannot answer one — while the full path, which the
         * matcher also accepts as a verbatim string, still resolves. Shortening there
         * would trade a handle that works for one that is refused, so it does not
         * happen: an old capture keeps its lineage.
         */
        private val positional: Boolean = snapshot.nodes.values
            .any { it.domNthOfType() != null || it.domNthChild() != null }

        /** How many captured paths would be matched by [suffix] used on its own. */
        private fun matches(suffix: String): Int =
            paths.count { it == suffix || it.endsWith(CHILD + suffix) }

        /** [CssHandle.of], against this pre-built index. */
        fun of(node: Node): String? {
            val full = node.domCssSelector() ?: return null
            node.domId()?.takeIf { it.isNotBlank() && idCounts[it] == 1 }?.let { return "#$it" }
            val segments = full.split(CHILD)
            // Longest-suffix-last: try one segment, then two, and stop at the first
            // that names exactly this node. `full` itself is the last candidate and
            // always matches, so the loop cannot fall through to a wrong answer.
            for (take in 1 until segments.size) {
                val candidate = segments.takeLast(take).joinToString(CHILD)
                if (!positional && candidate.contains(":nth-")) continue
                if (matches(candidate) == 1) return candidate
            }
            return full
        }
    }

    /**
     * The shortest unique handle for one node — build an [Index] instead when
     * shortening more than a couple, since this rebuilds the index each call.
     */
    fun of(snapshot: Snapshot, node: Node): String? = Index(snapshot).of(node)
}
