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
            selector.ref != null -> candidateList("ref", snapshot.nodes.keys)
            else -> "Use one of: --test-id, --resource-id, --css, --ref, or --point x,y."
        }
        val regionHint = selector.region?.let { regionHint(snapshot, selector, it) }
        return listOfNotNull(candidates, regionHint, scrollHint(snapshot), kernelHint(snapshot, selector))
            .joinToString(" ")
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
