package dev.reticle.cli

import dev.reticle.core.Node
import dev.reticle.core.NodeKind
import dev.reticle.core.Selector
import dev.reticle.core.Snapshot

/** Human-facing diagnostics for selector misses. */
internal object SelectorDiagnostics {
    fun pointMiss(snapshot: Snapshot, selector: Selector): String {
        val described = selector.describe()
        return "could not resolve selector '$described' to a point. ${hint(snapshot, selector)}"
    }

    fun nodeMiss(snapshot: Snapshot, selector: Selector): String {
        val described = selector.describe()
        return "no matching node for selector '$described'. ${hint(snapshot, selector)}"
    }

    fun nodeMiss(snapshot: Snapshot, key: String, value: String): String {
        val selector = when (key) {
            "testId" -> Selector(testId = value)
            "resourceId" -> Selector(resourceId = value)
            "css" -> Selector(cssSelector = value)
            "ref" -> Selector(ref = value)
            else -> Selector()
        }
        return nodeMiss(snapshot, selector)
    }

    private fun hint(snapshot: Snapshot, selector: Selector): String {
        val candidates = when {
            selector.testId != null -> candidateList("testId", snapshot.nodes.values.mapNotNull { it.testId })
            selector.resourceId != null -> candidateList("resourceId", snapshot.nodes.values.mapNotNull { it.resourceId })
            selector.cssSelector != null -> cssCandidateList(snapshot, selector.cssSelector!!)
            selector.ref != null -> refMiss(snapshot, selector.ref!!)
            // `--label` was missing from this list and that is how it stayed unused
            // while a real flow was driven by coordinates: on screens whose only
            // stable handle is the visible string (dialog buttons with generic ids —
            // `tvCancel` holding "Yes"), the one flag that would have worked was the
            // one the miss message did not mention. Named FIRST for that reason.
            else -> "No selector was given. Use --label \"<visible text>\" when the " +
                "on-screen string is the only stable handle, or one of: --test-id, " +
                "--resource-id, --css, --ref, --alias @N, or --point x,y."
        }
        val regionHint = selector.region?.let { regionHint(snapshot, selector, it) }
        // The recycling-list note is about a row that was never bound. For a REF miss
        // on a screen with a DOM on it, the cause is renumbering, not scrolling — and
        // measured on such a screen the note pointed at a container nothing had
        // touched, which is a wrong lead rather than a weak one.
        val scroll = if (selector.ref != null && snapshot.nodes.values.any { it.kind == NodeKind.domNode }) {
            null
        } else {
            scrollHint(snapshot)
        }
        return listOfNotNull(candidates, regionHint, scroll, kernelHint(snapshot, selector))
            .joinToString(" ")
    }

    /**
     * A `--ref` miss, which is almost never "there is no such element".
     *
     * Refs are traversal indices, valid for the snapshot they came from: any DOM
     * mutation or relayout renumbers them. Measured on a WebView-heavy screen, a ref
     * read out of one `ui report` was frequently dead ~1s later, and the answer was
     * a list of twelve NATIVE refs (`r3`, `r6`, …) — none of which can stand in for
     * a DOM node — followed by a note about recycling lists, when nothing had
     * scrolled and the document had simply re-rendered.
     *
     * So: say what a ref is, and name the handle that survives a re-render. `--css`
     * does, now that the matcher implements the `:nth-of-type()` the captured paths
     * are built from, so DOM candidates are offered as css handles rather than as
     * refs.
     */
    private fun refMiss(snapshot: Snapshot, ref: String): String {
        val domNodes = snapshot.nodes.values.filter { it.kind == NodeKind.domNode }
        val lifetime = "'$ref' is not in the current tree. A ref is a traversal INDEX, valid only " +
            "for the snapshot it came from: any relayout — or, in a WebView, any re-render — " +
            "renumbers the whole tree."
        if (domNodes.isEmpty()) {
            return "$lifetime ${candidateList("ref", snapshot.nodes.keys)} " +
                "Prefer a handle that survives a re-capture: --test-id / --resource-id / --label."
        }
        val handles = domNodes
            .filter { it.isInteractive || it.role == "textField" }
            .ifEmpty { domNodes }
            .map { addressableHandle(it) }
            .distinct()
            .take(6)
        return "$lifetime This screen carries ${domNodes.size} DOM node(s), and a DOM node cannot " +
            "be substituted by any of the native refs in the tree. Address it with --css, which " +
            "survives a re-render (the matcher implements :nth-of-type(n), so a captured path can " +
            "be shortened by hand): ${handles.joinToString(", ") { "'$it'" }}. " +
            "Re-run `ui report` / `ui compact --live` if you need the current refs."
    }

    /**
     * A handle that can actually be RE-RESOLVED, unlike [shortCssHandle]'s shortest
     * form: a bare `'input'` or `'span'` is short and matches the first of forty, so
     * offering it as a replacement for a dead ref would trade one wrong node for
     * another. Id first, then tag+classes, then the tail of the captured path —
     * which is addressable now that the matcher implements `:nth-of-type(n)`.
     */
    private fun addressableHandle(node: Node): String {
        node.domId()?.takeIf { it.isNotBlank() }?.let { return "#$it" }
        val tag = node.domTag().orEmpty()
        val classes = node.domClasses().take(2).joinToString("") { ".$it" }
        if (classes.isNotEmpty()) return tag + classes
        node.domCssSelector()?.split(" > ")?.takeLast(2)?.joinToString(" > ")?.let { return it }
        return tag.ifEmpty { node.ref }
    }

    /**
     * A `--css` miss on a screen whose web view is a third-party kernel is not a
     * wrong selector — there is no DOM to match against, and no wait or retry will
     * make one. Said here because this is exactly where an agent hits that wall.
     */
    private fun kernelHint(snapshot: Snapshot, selector: Selector): String? {
        if (selector.cssSelector == null) return null
        val kernels = snapshot.nodes.values.filter { it.domKernelUnsupported() }
        if (kernels.isEmpty()) return null
        val named = kernels.mapNotNull { it.domKernelName() }.distinct().joinToString(", ")
        return "Note: this screen has a suspected third-party WebView kernel ($named). " +
            "Reticle's DOM bridge is typed on android.webkit.WebView, so that view has NO DOM " +
            "at any level — target it as a plain view (--test-id / --point) instead of by CSS."
    }

    /**
     * A miss inside a recycling list is not the same failure as a wrong selector:
     * a container that keeps only its visible window bound has NO node for a
     * far-down row, so "not found" and "not bound yet" look identical. When the
     * screen holds a container that can still scroll, say so — stating the fact,
     * not promising the element is down there.
     */
    private fun scrollHint(snapshot: Snapshot): String? {
        val scrollable = snapshot.nodes.values
            .filter { it.scroll?.isScrollable == true }
            .take(3)
        if (scrollable.isEmpty()) return null
        val described = scrollable.joinToString(", ") { node ->
            val id = node.testId ?: node.resourceId ?: node.ref
            "'$id' (${node.scroll?.describe()})"
        }
        return "Note: the screen has scrollable content ($described); " +
            "a recycling list only binds its visible window, so an unbound row has no node yet."
    }

    private fun regionHint(snapshot: Snapshot, selector: Selector, region: String): String? {
        val node = nodeFor(snapshot, selector) ?: return null
        val labels = node.regions.mapNotNull { it.label }.distinct().take(8)
        val regionPart = if (labels.isEmpty()) {
            "No discovered sub-region labels on matched node."
        } else {
            "Region '$region' did not match discovered labels: ${labels.joinToString(", ") { "'$it'" }}."
        }
        val charPart = node.charGrid?.text?.takeIf { it.isNotBlank() }?.let {
            "Node text sample: '${it.take(80)}'."
        }
        return listOfNotNull(regionPart, charPart).joinToString(" ")
    }

    private fun nodeFor(snapshot: Snapshot, selector: Selector): Node? = when {
        selector.ref != null -> snapshot.nodes[selector.ref]
        selector.testId != null -> snapshot.nodes.values.firstOrNull { it.testId == selector.testId }
        selector.resourceId != null -> snapshot.nodes.values.firstOrNull { it.resourceId == selector.resourceId }
        selector.cssSelector != null -> snapshot.nodes.values.firstOrNull { it.domCssSelector() == selector.cssSelector }
        else -> null
    }

    /**
     * Candidates for a `--css` miss, ranked and short.
     *
     * Measured on a live page, a single miss printed twelve COMPLETE ancestor
     * chains — about 6 KB — and the twelve were an animated counter's list items
     * and a progress ring's `<circle>`s: unranked, and unrelated to what was asked
     * for. As a diagnostic it was worse than nothing, since it buried the one line
     * that said what happened.
     *
     * So: score each DOM node by how much of the query it actually carries (id,
     * classes, tag), print the shortest handle that names it rather than its
     * lineage, and stop at six. A node with none of the query's tokens is not a
     * candidate for it and is dropped entirely — an empty list is a better answer
     * than an arbitrary one.
     */
    private fun cssCandidateList(snapshot: Snapshot, query: String): String {
        val wanted = queryTokens(query)
        val scored = snapshot.nodes.values
            .filter { it.kind == NodeKind.domNode }
            .map { it to cssScore(it, wanted) }
            .filter { (_, score) -> score > 0 }
            .sortedByDescending { (_, score) -> score }
            .map { (node, _) -> shortCssHandle(node) }
            .distinct()
            .take(6)
        if (scored.isEmpty()) {
            val domNodes = snapshot.nodes.values.count { it.kind == NodeKind.domNode }
            return if (domNodes == 0) {
                "No DOM nodes were captured on this screen, so no css selector can match."
            } else {
                "None of the $domNodes captured DOM nodes carry any part of '$query' " +
                    "(its id, classes or tag). Read the tree with `ui compact --live` " +
                    "rather than guessing another selector."
            }
        }
        return "css candidates sharing part of '$query': " + scored.joinToString(", ") { "'$it'" }
    }

    /** The id / class / tag names a query mentions, lowercased. */
    private fun queryTokens(query: String): Set<String> =
        query.split(' ', '>', '\t')
            .flatMap { part -> part.split('#', '.') }
            .map { it.substringBefore(':').trim().lowercase() }
            .filter { it.isNotEmpty() }
            .toSet()

    private fun cssScore(node: Node, wanted: Set<String>): Int {
        if (wanted.isEmpty()) return 0
        var score = 0
        // An id is the most specific thing a query can name, so it outweighs the rest.
        node.domId()?.lowercase()?.let { if (it in wanted) score += 4 }
        node.domClasses().forEach { if (it.lowercase() in wanted) score += 2 }
        node.domTag()?.lowercase()?.let { if (it in wanted) score += 1 }
        return score
    }

    /** The shortest selector that names this node, rather than its lineage. */
    private fun shortCssHandle(node: Node): String {
        node.domId()?.takeIf { it.isNotBlank() }?.let { return "#$it" }
        val tag = node.domTag().orEmpty()
        val classes = node.domClasses().take(2).joinToString("") { ".$it" }
        if (tag.isNotEmpty() || classes.isNotEmpty()) return tag + classes
        // Nothing nameable: fall back to the tail of the captured path, not all of it.
        return node.domCssSelector()?.split(" > ")?.takeLast(2)?.joinToString(" > ") ?: node.ref
    }

    private fun candidateList(kind: String, raw: Iterable<String>): String {
        val values = raw.filter { it.isNotBlank() }.distinct().take(12).toList()
        if (values.isEmpty()) return "No $kind candidates are present in the current snapshot."
        return "$kind candidates (${values.size}${if (values.size == 12) "+" else ""}): " +
            values.joinToString(", ") { "'$it'" }
    }
}
