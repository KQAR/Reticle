package dev.reticle.cli

import dev.reticle.core.MetadataValue
import dev.reticle.core.Node
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
            selector.cssSelector != null -> candidateList("css", snapshot.nodes.values.mapNotNull { it.domCssSelector() })
            selector.ref != null -> candidateList("ref", snapshot.nodes.keys)
            else -> "Use one of: --test-id, --resource-id, --css, --ref, or --point x,y."
        }
        val regionHint = selector.region?.let { regionHint(snapshot, selector, it) }
        return listOfNotNull(candidates, regionHint).joinToString(" ")
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

    private fun candidateList(kind: String, raw: Iterable<String>): String {
        val values = raw.filter { it.isNotBlank() }.distinct().take(12).toList()
        if (values.isEmpty()) return "No $kind candidates are present in the current snapshot."
        return "$kind candidates (${values.size}${if (values.size == 12) "+" else ""}): " +
            values.joinToString(", ") { "'$it'" }
    }

    private fun Node.domCssSelector(): String? =
        (custom["domCssSelector"] as? MetadataValue.Text)?.value
}
