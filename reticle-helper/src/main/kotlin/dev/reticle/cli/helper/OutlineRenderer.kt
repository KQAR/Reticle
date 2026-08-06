package dev.reticle.cli

import dev.reticle.core.CssHandle
import dev.reticle.core.Node
import dev.reticle.core.Rect
import dev.reticle.core.Render
import dev.reticle.core.Size
import dev.reticle.core.Snapshot
import java.io.File
import java.security.MessageDigest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** Agent-facing outline renderer plus short-lived @N alias cache. */
internal object OutlineRenderer {
    private const val CACHE_VERSION = 1

    /** Sentinel for "no window seen yet" — null is a real value here. */
    private const val NO_WINDOW = "\u0000none"

    data class Entry(
        val alias: String,
        val ref: String,
        val role: String,
        val label: String?,
        val frame: Rect,
        val testId: String?,
        val resourceId: String?,
        val css: String?,
        val enabled: Boolean,
        val interactive: Boolean,
        val listIndex: Int? = null,
        val listSize: Int? = null,
        /** The window this node lives in, for grouping; null outside any window. */
        val windowRef: String? = null,
    )

    fun render(snapshot: Snapshot): Pair<String, List<Entry>> {
        val entries = collect(snapshot)
        val grouped = entries.mapNotNull { it.windowRef }.toSet().size > 1
        val text = buildString {
            append("Screen: ")
                .append(snapshot.screen.size.width.toInt())
                .append("x")
                .append(snapshot.screen.size.height.toInt())
                .append(" density=")
                .append(snapshot.screen.density)
                .append("\n")
            if (entries.isEmpty()) {
                append("(no visible labelled or interactive nodes)")
            } else if (!grouped) {
                // One window: headers would be pure noise.
                entries.forEach { appendLine(line(it)) }
            } else {
                // Stacked screens interleave when flattened by geometry alone, so
                // say which window each run of nodes belongs to. Entries already
                // come topmost-window-first, so this only has to announce changes.
                var current: String? = NO_WINDOW
                val top = snapshot.topWindowRef()
                for (entry in entries) {
                    if (entry.windowRef != current) {
                        current = entry.windowRef
                        appendLine(
                            current?.let { Render.windowHeader(snapshot.nodes[it], it, top = it == top) }
                                ?: "window: (none) — nodes captured outside any window"
                        )
                    }
                    // No indent: a header is a line a consumer can skip, but shifting
                    // every item would break line-anchored parsing of the outline.
                    appendLine(line(entry))
                }
            }
        }.trimEnd()
        return text to entries
    }

    fun writeCache(snapshot: Snapshot, entries: List<Entry>, serial: String?, packageName: String) {
        val file = cacheFile(serial, packageName)
        file.parentFile.mkdirs()
        val payload = ReticleJsonString.encode(cachePayload(snapshot, serial, packageName, entries))
        // Write atomically (temp + rename in the same dir) so a crash mid-write
        // can't leave a truncated cache that breaks the next alias resolution.
        val tmp = File.createTempFile("outline-", ".json", file.parentFile)
        try {
            tmp.writeText(payload)
            if (!tmp.renameTo(file)) file.writeText(payload) // rename failed (rare): direct write
        } finally {
            if (tmp.exists()) tmp.delete()
        }
    }

    fun resolveAlias(serial: String?, packageName: String, alias: String): Entry {
        val file = cacheFile(serial, packageName)
        if (!file.exists()) {
            throw CliError("no outline alias cache for '$packageName'. Run `reticle ui outline --live --package $packageName` first.")
        }
        val root = runCatching { ReticleJsonString.parse(file.readText()) }
            .getOrElse { throw corruptOutlineCache(packageName, "unreadable JSON") }
        val version = root["version"]?.jsonPrimitive?.int ?: 0
        if (version != CACHE_VERSION) {
            throw CliError("outline alias cache version mismatch. Re-run `reticle ui outline --live --package $packageName`.")
        }
        val entries = root["entries"]?.jsonArray ?: JsonArray(emptyList())
        val item = entries.map { it.jsonObject }.firstOrNull { it["alias"]?.jsonPrimitive?.content == alias }
            ?: throw CliError(aliasMiss(alias, entries))
        return entryFromJson(item, packageName)
    }

    /**
     * Does any part of this node's rect fall inside the display?
     *
     * Intersection, not containment: a row half off the bottom edge is still
     * something a caller can tap, and the point of the check is to drop what is
     * nowhere near the screen rather than to be strict about edges.
     */
    private fun onScreen(node: Node, screen: Size): Boolean {
        val frame = node.frame ?: return false
        if (frame.width <= 0.0 || frame.height <= 0.0) return false
        return frame.x < screen.width && frame.y < screen.height &&
            frame.x + frame.width > 0.0 && frame.y + frame.height > 0.0
    }

    private fun collect(snapshot: Snapshot): List<Entry> {
        // Windows first (topmost first), geometry within a window. Numbering then
        // starts in the window the user is actually looking at, instead of being
        // dominated by a background screen's nodes — the `@N` half of the same
        // complaint: aliases were least useful exactly when the screen was stacked.
        val windowOrder = snapshot.windowRefs().withIndex().associate { (i, ref) -> ref to i }
        val windowOf = HashMap<String, String?>()
        // On screen, not merely in the tree. `outline` is the ad-hoc "what can I
        // act on right now" view and its aliases are meant to be tapped, so a node
        // scrolled far past the fold is not a candidate: measured on a real home
        // screen, a 1080x2412 device produced 135 aliases whose last entry sat at
        // y=10800, while about 15 were actually visible. The rest were not wrong —
        // they were unreachable without a scroll, numbered as though they were not.
        val screen = snapshot.screen.size
        // One index for the whole outline: a DOM node's handle is the shortest
        // suffix of its captured path that still names it alone, and deciding that
        // per node against the whole node set would be quadratic on a page-heavy
        // screen. See `CssHandle` for why the full path is not what gets printed.
        val cssIndex = CssHandle.Index(snapshot)
        val nodes = snapshot.nodes.values
            .filter { it.isVisible && it.frame != null && (it.isInteractive || it.hasLabelOrSelector()) }
            .filter { node -> onScreen(node, screen) }
            .onEach { windowOf[it.ref] = snapshot.windowRefOf(it.ref) }
            .sortedWith(
                compareBy<Node>({ -(windowOf[it.ref]?.let { w -> windowOrder[w] } ?: -1) })
                    .thenBy { it.frame?.y ?: 0.0 }
                    .thenBy { it.frame?.x ?: 0.0 }
            )
        val entries = nodes.mapIndexed { index, node ->
            Entry(
                alias = "@${index + 1}",
                ref = node.ref,
                role = node.role ?: node.typeName,
                label = node.contentDescription ?: node.text,
                frame = node.frame!!,
                testId = node.testId,
                resourceId = node.resourceId,
                css = cssIndex.of(node),
                enabled = node.isEnabled,
                interactive = node.isInteractive,
                windowRef = windowOf[node.ref],
            )
        }
        return withListOrdinals(entries)
    }

    private fun withListOrdinals(entries: List<Entry>): List<Entry> {
        val groups = entries
            .withIndex()
            .groupBy { (_, entry) -> listKey(entry) }
            .filterValues { group -> group.size >= 2 }
        if (groups.isEmpty()) return entries
        val ordinalByAlias = mutableMapOf<String, Pair<Int, Int>>()
        groups.values.forEach { group ->
            group.sortedWith(compareBy({ it.value.frame.y }, { it.value.frame.x })).forEachIndexed { index, item ->
                ordinalByAlias[item.value.alias] = (index + 1) to group.size
            }
        }
        return entries.map { entry ->
            val ordinal = ordinalByAlias[entry.alias] ?: return@map entry
            entry.copy(listIndex = ordinal.first, listSize = ordinal.second)
        }
    }

    private fun line(entry: Entry): String = buildString {
        append(entry.alias).append(" ")
        selector(entry)?.let { append(it).append(" ") }
        append(entry.role)
        entry.label?.takeIf { it.isNotBlank() }?.let { append(" \"").append(clean(it).take(48)).append("\"") }
        append(" [")
            .append(entry.frame.x.toInt()).append(",")
            .append(entry.frame.y.toInt()).append(" ")
            .append(entry.frame.width.toInt()).append("x")
            .append(entry.frame.height.toInt()).append("]")
        if (!entry.enabled) append(" disabled")
        if (entry.interactive) append(" tappable")
        if (entry.listIndex != null && entry.listSize != null) {
            append(" item ").append(entry.listIndex).append("/").append(entry.listSize)
        }
    }

    private fun selector(entry: Entry): String? =
        entry.testId?.let { "#$it" }
            ?: entry.resourceId?.let { "@$it" }
            ?: entry.css?.let { "css=$it" }
            ?: entry.ref

    private fun cachePayload(snapshot: Snapshot, serial: String?, packageName: String, entries: List<Entry>): JsonObject =
        buildJsonObject {
            put("version", CACHE_VERSION)
            put("serial", serial ?: "")
            put("package", packageName)
            put("capturedAtMillis", snapshot.capturedAtMillis)
            put("screen", buildJsonObject {
                put("width", snapshot.screen.size.width)
                put("height", snapshot.screen.size.height)
                put("density", snapshot.screen.density)
            })
            put("entries", buildJsonArray {
                entries.forEach { e ->
                    add(buildJsonObject {
                        put("alias", e.alias)
                        put("ref", e.ref)
                        put("role", e.role)
                        e.label?.let { put("label", it) }
                        e.testId?.let { put("testId", it) }
                        e.resourceId?.let { put("resourceId", it) }
                        e.css?.let { put("css", it) }
                        put("enabled", e.enabled)
                        put("interactive", e.interactive)
                        e.listIndex?.let { put("listIndex", it) }
                        e.listSize?.let { put("listSize", it) }
                        put("frame", buildJsonObject {
                            put("x", e.frame.x)
                            put("y", e.frame.y)
                            put("width", e.frame.width)
                            put("height", e.frame.height)
                        })
                    })
                }
            })
        }

    /**
     * Parse one cached entry defensively. The cache is Reticle's own round-trip
     * and guarded by [CACHE_VERSION], but a truncated/hand-edited file would
     * otherwise surface a raw NPE / cast exception here; instead throw a clean
     * CliError that tells the agent to re-run the outline.
     */
    private fun entryFromJson(item: JsonObject, packageName: String): Entry {
        fun str(key: String): String =
            (item[key] as? JsonPrimitive)?.contentOrNull ?: throw corruptOutlineCache(packageName, "missing '$key'")
        val frame = (item["frame"] as? JsonObject) ?: throw corruptOutlineCache(packageName, "missing 'frame'")
        fun num(key: String): Double =
            (frame[key] as? JsonPrimitive)?.contentOrNull?.toDoubleOrNull()
                ?: throw corruptOutlineCache(packageName, "frame.$key is not a number")
        fun opt(key: String): String? = (item[key] as? JsonPrimitive)?.contentOrNull
        return Entry(
            alias = str("alias"),
            ref = str("ref"),
            role = str("role"),
            label = opt("label"),
            frame = Rect(x = num("x"), y = num("y"), width = num("width"), height = num("height")),
            testId = opt("testId"),
            resourceId = opt("resourceId"),
            css = opt("css"),
            enabled = opt("enabled") == "true",
            interactive = opt("interactive") == "true",
            listIndex = opt("listIndex")?.toIntOrNull(),
            listSize = opt("listSize")?.toIntOrNull(),
        )
    }

    private fun corruptOutlineCache(packageName: String, detail: String): CliError =
        CliError("outline alias cache for '$packageName' is corrupt ($detail). Re-run `reticle ui outline --live --package $packageName`.")

    private fun listKey(entry: Entry): String {
        val frame = entry.frame
        val quantizedX = (frame.x / 24.0).toInt()
        val quantizedWidth = (frame.width / 24.0).toInt()
        val quantizedHeight = (frame.height / 12.0).toInt()
        // Keyed by window too: two stacked screens can each hold a same-shaped row,
        // and merging them would report "item 3/8" for a list of four.
        return "${entry.windowRef}|${entry.role}|$quantizedX|$quantizedWidth|$quantizedHeight|${entry.interactive}"
    }

    private fun aliasMiss(alias: String, entries: JsonArray): String {
        val aliases = entries.mapNotNull { it.jsonObject["alias"]?.jsonPrimitive?.content }.take(12)
        return "outline alias '$alias' not found. Cached aliases: ${aliases.joinToString(", ")}. Re-run `reticle ui outline --live` after navigation."
    }

    private fun cacheFile(serial: String?, packageName: String): File {
        val home = System.getProperty("user.home")
        val serialKey = sanitize(serial ?: "default")
        return File(File(File(home, ".reticle"), "aliases"), "$serialKey/${sanitize(packageName)}/last-outline.json")
    }

    private fun sanitize(value: String): String {
        val safe = value.replace(Regex("[^A-Za-z0-9._-]"), "_")
        if (safe.length <= 80) return safe
        val digest = MessageDigest.getInstance("SHA-256").digest(value.toByteArray())
            .take(6)
            .joinToString("") { "%02x".format(it) }
        return safe.take(72) + "-" + digest
    }

    private fun Node.hasLabelOrSelector(): Boolean =
        testId != null || resourceId != null || contentDescription != null || !text.isNullOrBlank() || domCssSelector() != null

    private fun clean(value: String): String = value.replace('\n', ' ').replace('\r', ' ')
}

private object ReticleJsonString {
    fun encode(value: JsonObject): String =
        dev.reticle.core.ReticleJson.compact.encodeToString(JsonObject.serializer(), value)

    fun parse(value: String): JsonObject =
        dev.reticle.core.ReticleJson.compact.parseToJsonElement(value).jsonObject
}
