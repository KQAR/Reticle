package dev.reticle.cli

import dev.reticle.core.CssSelectorMatch
import dev.reticle.core.Node
import dev.reticle.core.Snapshot
import kotlinx.serialization.json.JsonObject

/** Locate a concrete snapshot node by any helper-supported selector. */
internal fun findNode(snapshot: Snapshot, params: JsonObject): Node? {
    val testId = params.str("testId")
    val resourceId = params.str("resourceId")
    val cssSelector = params.str("css") ?: params.str("cssSelector")
    val ref = params.str("ref")
    return when {
        testId != null -> snapshot.nodes.values.firstOrNull { it.testId == testId }
        resourceId != null -> snapshot.nodes.values.firstOrNull { it.resourceId == resourceId }
        // Through the shared matcher, not a second exact comparison of its own:
        // this used to be an independent copy of the rule and had already drifted
        // from what `--css` is documented to accept.
        cssSelector != null -> CssSelectorMatch.find(snapshot, cssSelector)
        ref != null -> snapshot.nodes[ref]
        else -> throw CliError("node needs testId, resourceId, css, or ref")
    }
}
