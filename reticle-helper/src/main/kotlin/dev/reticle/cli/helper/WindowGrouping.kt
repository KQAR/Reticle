package dev.reticle.cli

import dev.reticle.core.CompactObservation
import dev.reticle.core.Node
import dev.reticle.core.Snapshot

/**
 * Group a flat projection by the window each item belongs to, topmost first.
 *
 * A snapshot holds every attached window of the process, and on Android a screen
 * stacked over a still-live one is the common case rather than the exception. A
 * flat list sorted by geometry then INTERLEAVES them: the two framework roots
 * appear twice, `#etContent` appears four times, and the fields of the screen
 * actually being driven sit a dozen aliases apart with unrelated content wedged
 * between them. Measured on a real form: the relevant nodes were about a third of
 * a 99-line outline.
 *
 * This is a presentation change and drops nothing — every node still appears,
 * under a header naming its window. The item lines themselves are left BYTE-FOR-BYTE
 * unchanged, indentation included: a header is a new line a consumer can ignore,
 * while indenting the items would break every `grep '^#selector'` written against
 * this output — and since a screen stacked over a live one is the Android common
 * case, that would break them most of the time rather than rarely. Measured: it
 * broke this repo's own e2e assertions on the first run. Scoping (`--window top`) is the other half and
 * lives in [Snapshot.scopedToWindow], so a caller can choose between "show me
 * everything, organised" and "show me only the screen I am driving".
 */
internal object WindowGrouping {

    /**
     * Header + item lines for [compact], grouped by window when there is more than
     * one. With a single window the headers would be pure noise, so they are
     * omitted and the output is byte-identical to the ungrouped rendering.
     */
    fun lines(snapshot: Snapshot, compact: CompactObservation): List<String> {
        val order = snapshot.windowRefs()
        val present = compact.items.mapNotNull { it.windowRef }.toSet()
        if (present.size <= 1) return compact.items.map { it.line() }
        val out = ArrayList<String>(compact.items.size + present.size + 1)
        // Topmost first: the window the user is looking at is the one an agent
        // wants to read, and burying it under the background page is the current
        // complaint in a different shape.
        for (ref in order.asReversed()) {
            val items = compact.items.filter { it.windowRef == ref }
            if (items.isEmpty()) continue
            out += header(snapshot.nodes[ref], ref, top = ref == snapshot.topWindowRef())
            items.forEach { out += it.line() }
        }
        // Anything outside a window (the application root's own children) keeps its
        // place rather than being silently dropped.
        val loose = compact.items.filter { it.windowRef == null }
        if (loose.isNotEmpty()) {
            out += "window: (none) — nodes captured outside any window"
            loose.forEach { out += it.line() }
        }
        return out
    }

    /**
     * One line naming a window: its ref, what it is, and whether it is on top.
     * `[top]` is the actionable half — a node in any other window is behind the
     * screen being driven, which `occluded-by:` only implies.
     */
    fun header(node: Node?, ref: String, top: Boolean): String {
        val what = node?.testId ?: node?.resourceId ?: node?.typeName?.substringAfterLast('.') ?: "window"
        val where = node?.frame?.let {
            " [${it.x.toInt()},${it.y.toInt()} ${it.width.toInt()}x${it.height.toInt()}]"
        } ?: ""
        return "window $ref $what$where" + if (top) " [top]" else " [behind the top window]"
    }
}
