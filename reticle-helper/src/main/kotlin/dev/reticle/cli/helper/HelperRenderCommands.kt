package dev.reticle.cli

import dev.reticle.cli.platform.Platforms
import dev.reticle.core.CompactObservation
import dev.reticle.core.ReticleJson
import dev.reticle.core.SemanticTree
import dev.reticle.core.Snapshot
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File

/** Local snapshot rendering commands; no device I/O unless `live` is requested. */
internal object HelperRenderCommands {
    fun render(params: JsonObject): JsonElement {
        val view = params.str("view") ?: throw CliError("render needs 'view'")
        val snapshot = snapshotFor(params)
        val text = renderView(view, snapshot, params)
        if (view == "outline") {
            params.str("package")?.let { pkg ->
                val (_, entries) = OutlineRenderer.render(snapshot)
                OutlineRenderer.writeCache(snapshot, entries, params.str("serial"), pkg)
            }
        }
        return buildJsonObject { put("text", text) }
    }

    private fun snapshotFor(params: JsonObject): Snapshot {
        if (params["live"]?.jsonPrimitive?.content == "true") {
            val pkg = params.str("package") ?: throw CliError("live render needs 'package'")
            val device = Platforms.current().device(params.str("serial"))
            device.ensureDeviceReady()
            val client = runtimeClientFor(device, pkg, params)
            assertHealthy(client, pkg)
            return client.snapshot()
        }
        val path = params.str("snapshot") ?: throw CliError("render needs 'snapshot' path (or live + package)")
        val file = File(path)
        if (!file.exists()) throw CliError("snapshot file not found: $path")
        return ReticleJson.instance.decodeFromString(Snapshot.serializer(), file.readText())
    }

    private fun renderView(view: String, snapshot: Snapshot, params: JsonObject): String = when (view) {
        "tree" -> renderViewTree(snapshot, params.intOrNull("depth") ?: Int.MAX_VALUE)
        "semantics" -> renderSemanticTree(SemanticTree.build(snapshot), params.intOrNull("depth") ?: Int.MAX_VALUE)
        "compact" -> CompactObservation.from(snapshot).items.joinToString("\n") { it.line() }
        "outline" -> OutlineRenderer.render(snapshot).first
        "node" -> renderNode(snapshot, params)
        "regions" -> renderRegions(snapshot)
        else -> throw CliError("unknown render view '$view'")
    }

    private fun renderNode(snapshot: Snapshot, params: JsonObject): String {
        val selector = selectorFrom(params)
        val node = findNode(snapshot, params) ?: throw CliError(SelectorDiagnostics.nodeMiss(snapshot, selector))
        return ReticleJson.instance.encodeToString(dev.reticle.core.Node.serializer(), node)
    }

    private fun renderViewTree(snapshot: Snapshot, maxDepth: Int): String = buildString {
        fun walk(ref: String, depth: Int) {
            if (depth > maxDepth) return
            val node = snapshot.nodes[ref] ?: return
            val sel = node.testId?.let { "#$it" } ?: node.resourceId?.let { "@$it" } ?: node.ref
            val label = node.text ?: node.contentDescription
            append("  ".repeat(depth)).append("$sel ${node.role ?: node.typeName}${label?.let { " \"${it.take(30)}\"" } ?: ""}").append("\n")
            node.children.forEach { walk(it, depth + 1) }
        }
        walk(snapshot.rootRef, 0)
    }.trimEnd()

    private fun renderSemanticTree(tree: SemanticTree, maxDepth: Int): String = buildString {
        fun walk(ref: String, depth: Int) {
            if (depth > maxDepth) return
            val node = tree.nodes[ref] ?: return
            val sel = node.testId?.let { "#$it" } ?: node.resourceId?.let { "@$it" } ?: node.ref
            append("  ".repeat(depth)).append("$sel ${node.role}${node.label?.let { " \"${it.take(30)}\"" } ?: ""}").append("\n")
            node.children.forEach { walk(it, depth + 1) }
        }
        val roots = tree.nodes.values
            .filter { it.parentRef == null || !tree.nodes.containsKey(it.parentRef) }
            .map { it.ref }
        if (roots.isEmpty()) append("(no semantic nodes)") else roots.forEach { walk(it, 0) }
    }.trimEnd()

    private fun renderRegions(snapshot: Snapshot): String = buildString {
        var any = false
        for (node in snapshot.nodes.values) {
            if (node.regions.isEmpty() && !node.suspectedMultiRegion) continue
            any = true
            val sel = node.testId?.let { "#$it" } ?: node.resourceId?.let { "@$it" } ?: node.ref
            append("$sel ${node.role ?: node.typeName}${node.text?.let { " \"${it.take(40)}\"" } ?: ""}").append("\n")
            if (node.suspectedMultiRegion) {
                append("    ! suspectedMultiRegion: self-drawn control\n")
                node.charGrid?.let { g ->
                    append("    charGrid: ${g.lines.size} line(s)${if (g.approximate) " (approximate)" else ""}\n")
                }
            }
            for (r in node.regions) {
                val rect = r.rects.firstOrNull()
                val where = rect?.let { "[${it.x.toInt()},${it.y.toInt()} ${it.width.toInt()}x${it.height.toInt()}]" }
                    ?: "(no rect)"
                append("    - ${r.source} \"${r.label?.take(40) ?: ""}\"${r.target?.let { " -> $it" } ?: ""}${r.color?.let { " color=$it" } ?: ""} $where\n")
            }
        }
        if (!any) append("(no multi-region nodes found)")
    }.trimEnd()
}
