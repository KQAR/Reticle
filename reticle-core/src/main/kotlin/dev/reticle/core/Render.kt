package dev.reticle.core

/**
 * The text projections an agent actually reads — `compact`, `tree`,
 * `semantics`, `regions` — as pure functions over a [Snapshot].
 *
 * These live HERE, beside the derivations they render, for the same reason
 * [StyleObservation.render] does: every one of them exists twice (Kotlin for the
 * Android helper, Swift in `ReticleProtocol` for the iOS host, because the two
 * hosts are different binaries), and a projection whose *derivation* is shared
 * while its *formatting* is not has only half a contract. `compact` is the
 * default agent surface and had already drifted that way once; the renderers were
 * in the helper, where nothing shared could pin them.
 *
 * Kept identical to `Render` in ReticleProtocol, and pinned for both by
 * reticle-protocol/fixtures/snapshot-render.cases.json. The helper's
 * `HelperRenderCommands` keeps only what is genuinely host-side: fetching or
 * loading the snapshot, window scoping, the `@N` alias cache, and `node`
 * (which renders through the selector diagnostics only the helper has).
 */
object Render {

    /**
     * The compact observation as text: the two screen-level facts that no node
     * carries, the item lines grouped by window, and a footer naming what the
     * projection folded.
     *
     * Order is deliberate. Lost window focus outranks the keyboard line: when
     * another process's window holds input focus (a permission prompt, a
     * biometric sheet — presented by another process and therefore absent from
     * this tree) NOTHING here is tappable, however tappable it looks. The
     * keyboard line comes next because the IME is likewise invisible to the node
     * walk, so without it an agent cannot know that a "tappable" item near the
     * bottom would hit the keys. The fold line comes last and once: the folded
     * layers are anonymous and still in the snapshot, but a token-cheap view must
     * not quietly read as the whole tree.
     */
    fun compact(snapshot: Snapshot): String {
        val observation = CompactObservation.from(snapshot)
        val lines = windowGrouped(snapshot, observation)
        val focusLine = if (snapshot.screen.windowFocused == false) {
            "window: UNFOCUSED — another window has input focus (a system prompt is not part of " +
                "this app's tree); taps will not reach these items"
        } else {
            null
        }
        val foldLine = observation.collapsedWrappers.takeIf { it > 0 }?.let {
            "($it anonymous layer(s) folded into the node they wrap — all still in the " +
                "snapshot, reachable with `ui node --ref`)"
        }
        // Unlike the fold, a truncated item is GONE from this view; the line is
        // what keeps the cap from reading as "that was the whole screen".
        val truncLine = observation.truncatedItems.takeIf { it > 0 }?.let {
            "($it more item(s) beyond this projection's cap — NOT listed here; " +
                "they are still in the snapshot, reachable with `ui tree` / `ui node --ref`)"
        }
        val keyboard = snapshot.screen.keyboard
            ?: return (listOfNotNull(focusLine) + lines + listOfNotNull(foldLine, truncLine))
                .joinToString("\n")
        val header = if (keyboard.visible) {
            val where = keyboard.frame?.let { " [${rect(it)}]" } ?: ""
            val covered = observation.items.count { it.occludedBy == CompactObservation.OCCLUDER_KEYBOARD }
            "keyboard: visible$where" +
                (if (covered > 0) " — $covered item(s) occluded" else "") +
                " (dismiss with `act hide-keyboard`)"
        } else {
            "keyboard: hidden"
        }
        return (listOfNotNull(focusLine) + listOf(header) + lines + listOfNotNull(foldLine, truncLine))
            .joinToString("\n")
    }

    /**
     * Header + item lines grouped by window, topmost first, when more than one
     * window has items.
     *
     * A snapshot holds every attached window of the process, and a screen stacked
     * over a still-live one is the common case rather than the exception. A flat
     * list sorted by geometry INTERLEAVES them: the framework roots appear twice,
     * a repeated framework id appears four times, and the fields of the screen
     * actually being driven sit a dozen items apart with unrelated content wedged
     * between them.
     *
     * This drops nothing — every item still appears, under a header naming its
     * window — and the item lines stay BYTE-FOR-BYTE unchanged, indentation
     * included: a header is a new line a consumer can ignore, while indenting the
     * items would break every `grep '^#selector'` written against this output.
     * With a single window the headers would be pure noise, so the output is then
     * byte-identical to the ungrouped rendering. Scoping (`--window top`) is the
     * other half and lives in [Snapshot.scopedToWindow].
     */
    fun windowGrouped(snapshot: Snapshot, observation: CompactObservation): List<String> {
        val present = observation.items.mapNotNull { it.windowRef }.toSet()
        if (present.size <= 1) return observation.items.map { it.line() }
        val out = ArrayList<String>(observation.items.size + present.size + 1)
        val top = snapshot.topWindowRef()
        for (ref in snapshot.windowRefs().asReversed()) {
            val items = observation.items.filter { it.windowRef == ref }
            if (items.isEmpty()) continue
            out += windowHeader(snapshot.nodes[ref], ref, top = ref == top)
            items.forEach { out += it.line() }
        }
        // Anything outside a window (the application root's own children) keeps
        // its place rather than being silently dropped.
        val loose = observation.items.filter { it.windowRef == null }
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
    fun windowHeader(node: Node?, ref: String, top: Boolean): String {
        val what = node?.testId
            ?: node?.resourceId
            ?: node?.typeName?.substringAfterLast('.')
            ?: "window"
        val where = node?.frame?.let { " [${rect(it)}]" } ?: ""
        return "window $ref $what$where" + if (top) " [top]" else " [behind the top window]"
    }

    /** The full view tree, indented, one line per node. */
    fun tree(snapshot: Snapshot, maxDepth: Int = Int.MAX_VALUE): String = buildString {
        fun walk(ref: String, depth: Int) {
            if (depth > maxDepth) return
            val node = snapshot.nodes[ref] ?: return
            val label = node.text ?: node.contentDescription
            append("  ".repeat(depth))
                .append(selectorOf(node))
                .append(" ")
                .append(node.role ?: node.typeName)
                .append(label?.let { " \"${it.take(30)}\"" } ?: "")
                .append("\n")
            node.children.forEach { walk(it, depth + 1) }
        }
        walk(snapshot.rootRef, 0)
    }.trimEnd()

    /** The semantic projection, indented, one line per node. */
    fun semantics(tree: SemanticTree, maxDepth: Int = Int.MAX_VALUE): String = buildString {
        fun walk(ref: String, depth: Int) {
            if (depth > maxDepth) return
            val node = tree.nodes[ref] ?: return
            append("  ".repeat(depth))
                .append(selectorOf(node.testId, node.resourceId, node.ref))
                .append(" ")
                .append(node.role)
                .append(node.label?.let { " \"${it.take(30)}\"" } ?: "")
                .append("\n")
            node.children.forEach { walk(it, depth + 1) }
        }
        // Document order, so a tree with several roots prints in the same order on
        // both platforms — iterating the node map instead means insertion order,
        // which is a decoding detail rather than a fact about the screen.
        val roots = semanticRefsInDocumentOrder(tree).filter { ref ->
            val node = tree.nodes[ref] ?: return@filter false
            node.parentRef == null || !tree.nodes.containsKey(node.parentRef)
        }
        if (roots.isEmpty()) append("(no semantic nodes)") else roots.forEach { walk(it, 0) }
    }.trimEnd()

    /** Every multi-region node, its discovered regions, and its char grid. */
    fun regions(snapshot: Snapshot): String = buildString {
        var any = false
        for (ref in snapshot.refsInDocumentOrder()) {
            val node = snapshot.nodes[ref] ?: continue
            if (node.regions.isEmpty() && !node.suspectedMultiRegion) continue
            any = true
            append(selectorOf(node))
                .append(" ")
                .append(node.role ?: node.typeName)
                .append(node.text?.let { " \"${it.take(40)}\"" } ?: "")
                .append("\n")
            if (node.suspectedMultiRegion) {
                append("    ! suspectedMultiRegion: self-drawn control\n")
                node.charGrid?.let { grid ->
                    append("    charGrid: ${grid.lines.size} line(s)")
                        .append(if (grid.approximate) " (approximate)" else "")
                        .append("\n")
                }
            }
            for (region in node.regions) {
                val where = region.rects.firstOrNull()?.let { "[${rect(it)}]" } ?: "(no rect)"
                append("    - ${region.source} \"${region.label?.take(40) ?: ""}\"")
                    .append(region.target?.let { " -> $it" } ?: "")
                    .append(region.color?.let { " color=$it" } ?: "")
                    .append(" $where\n")
            }
        }
        if (!any) append("(no multi-region nodes found)")
    }.trimEnd()

    /** Geometry + style + provenance for every node that has any. */
    fun style(snapshot: Snapshot): String = StyleObservation.from(snapshot).render()

    private fun selectorOf(node: Node): String = selectorOf(node.testId, node.resourceId, node.ref)

    private fun selectorOf(testId: String?, resourceId: String?, ref: String): String =
        testId?.let { "#$it" } ?: resourceId?.let { "@$it" } ?: ref

    private fun rect(frame: Rect): String =
        "${frame.x.toInt()},${frame.y.toInt()} ${frame.width.toInt()}x${frame.height.toInt()}"

    private fun semanticRefsInDocumentOrder(tree: SemanticTree): List<String> {
        val out = ArrayList<String>(tree.nodes.size)
        val seen = HashSet<String>()
        fun visit(ref: String) {
            if (ref in seen) return
            val node = tree.nodes[ref] ?: return
            seen += ref
            out += ref
            node.children.forEach(::visit)
        }
        visit(tree.rootRef)
        tree.nodes.keys.sorted().forEach(::visit)
        return out
    }
}
