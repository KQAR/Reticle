package dev.reticle.cli

import dev.reticle.cli.platform.android.Adb
import dev.reticle.core.Render
import dev.reticle.core.ReticleJson
import dev.reticle.core.SemanticTree
import dev.reticle.core.Snapshot
import dev.reticle.core.requireSupportedSchema
import java.io.File
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** Local snapshot rendering commands; no device I/O unless `live` is requested. */
internal object HelperRenderCommands {
    fun render(params: JsonObject): JsonElement {
        val view = params.str("view") ?: throw CliError("render needs 'view'")
        val snapshot = scopeToWindow(snapshotFor(params), params.str("window"))
        val text = renderView(view, snapshot, params)
        if (view == "outline") {
            params.str("package")?.let { pkg ->
                // Cache from the same (possibly window-scoped) snapshot the text
                // came from: @N must mean what the caller just read.
                val (_, entries) = OutlineRenderer.render(snapshot)
                OutlineRenderer.writeCache(snapshot, entries, params.str("serial"), pkg)
            }
        }
        return buildJsonObject { put("text", text) }
    }

    /**
     * Narrow the capture to one window when `--window` asked for it.
     *
     * Applied to the SNAPSHOT, before any view runs, so every projection —
     * `tree`, `compact`, `outline`, `style` — and the `@N` numbering that follows
     * from the outline narrow identically, and no renderer has to learn about
     * windows. A ref that names no window in this capture is an error naming the
     * ones that exist: silently rendering everything would look like the scope had
     * been applied and found the screen busy.
     */
    private fun scopeToWindow(snapshot: Snapshot, window: String?): Snapshot {
        if (window == null) return snapshot
        return snapshot.scopedToWindow(window) ?: throw CliError(
            "no window '$window' in this capture. Windows here (bottom to top): " +
                snapshot.windowRefs().joinToString(", ").ifBlank { "(none — this capture has no window nodes)" } +
                ". Use `--window top` for whichever is on top."
        )
    }

    private fun snapshotFor(params: JsonObject): Snapshot {
        if (params["live"]?.jsonPrimitive?.content == "true") {
            val pkg = params.str("package") ?: throw CliError("live render needs 'package'")
            val device = Adb.forSerial(params.str("serial"))
            device.ensureDeviceReady()
            val client = runtimeClientFor(device, pkg, params)
            assertHealthy(client, pkg)
            return client.snapshot()
        }
        val path = params.str("snapshot") ?: throw CliError("render needs 'snapshot' path (or live + package)")
        val file = File(path)
        if (!file.exists()) throw CliError("snapshot file not found: $path")
        return ReticleJson.instance.decodeFromString(Snapshot.serializer(), file.readText())
            .requireSupportedSchema()
    }

    /**
     * Every projection except `outline` and `node` is rendered by
     * [dev.reticle.core.Render], the twin of `Render` in ReticleProtocol — so the
     * Android helper and the iOS host cannot format one snapshot two ways.
     * `outline` is the Android-only `@N` alias cache, and `node` needs the
     * selector diagnostics that only the helper has.
     */
    private fun renderView(view: String, snapshot: Snapshot, params: JsonObject): String = when (view) {
        "tree" -> Render.tree(snapshot, params.intOrNull("depth") ?: Int.MAX_VALUE)
        "semantics" -> Render.semantics(SemanticTree.build(snapshot), params.intOrNull("depth") ?: Int.MAX_VALUE)
        "compact" -> Render.compact(snapshot)
        "outline" -> OutlineRenderer.render(snapshot).first
        "node" -> renderNode(snapshot, params)
        "regions" -> Render.regions(snapshot)
        "style" -> Render.style(snapshot)
        "coverage" -> Render.coverage(snapshot)
        else -> throw CliError("unknown render view '$view'")
    }

    private fun renderNode(snapshot: Snapshot, params: JsonObject): String {
        val selector = selectorFrom(params)
        val node = findNode(snapshot, params) ?: throw CliError(SelectorDiagnostics.nodeMiss(snapshot, selector))
        return ReticleJson.instance.encodeToString(dev.reticle.core.Node.serializer(), node)
    }

}
