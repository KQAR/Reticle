package dev.reticle.cli

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
        cssSelector != null -> snapshot.nodes.values.firstOrNull { it.domCssSelector() == cssSelector }
        ref != null -> snapshot.nodes[ref]
        else -> throw CliError("node needs testId, resourceId, css, or ref")
    }
}
