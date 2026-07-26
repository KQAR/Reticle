package dev.reticle.cli

import dev.reticle.core.Node
import dev.reticle.core.Point
import dev.reticle.core.Rect
import dev.reticle.core.Selector
import dev.reticle.core.SemanticTree
import dev.reticle.core.Snapshot

/**
 * Resolves a selector to a screen point for input dispatch. Encodes the
 * architecture rule:
 *
 *   "Use the semantic tree first for movement and input; selector actions
 *    should only fall back to view frames when no semantic match exists."
 *
 * This is the Android half of a two-language contract: `SelectorResolution` in
 * `reticle-swift` is the iOS half, and both are pinned by
 * `reticle-protocol/fixtures/selector-resolution.cases.json`. The fixture exists
 * because the two had drifted — change resolution here only together with a case
 * there, or iOS ships a different answer for the same command.
 */
class SelectorResolver(
    private val snapshot: Snapshot,
    private val semantic: SemanticTree,
) {

    data class Resolved(val point: Point, val source: String, val ref: String?)

    fun resolve(selector: Selector): Resolved? {
        // 0. An explicit point is the escape hatch for when resolution cannot
        //    work, so nothing may override it — not even a --region needle passed
        //    alongside it. (`resolveInputTarget` also short-circuits it before the
        //    capture; this keeps the resolver's own order honest about that.)
        selector.point?.let { return Resolved(it, "point", null) }

        // 1. Region-within-node: target a sub-region (span / virtual / char
        //    range) inside a node, the multi-region case neither tree collapses.
        if (selector.region != null) {
            val node = nodeFor(selector) ?: return null
            return resolveRegion(node, selector.region!!)
        }

        // 2. Semantic tree first. Use the matched node's own ref rather than
        //    re-scanning for it — the semantic tree preserves snapshot refs.
        selector.testId?.let { id ->
            semantic.findByTestId(id)?.let { n -> n.frame?.let { return Resolved(center(it), "semantic:testId", n.ref) } }
        }
        selector.resourceId?.let { id ->
            semantic.findByResourceId(id)?.let { n -> n.frame?.let { return Resolved(center(it), "semantic:resourceId", n.ref) } }
        }
        selector.cssSelector?.let { css ->
            nodeByCssSelector(css)?.let { n -> n.frame?.let { return Resolved(center(it), "dom:css", n.ref) } }
        }
        selector.ref?.let { ref ->
            semantic.node(ref)?.frame?.let { return Resolved(center(it), "semantic:ref", ref) }
        }
        selector.label?.let { label ->
            labelMatch(label)?.let { n -> n.frame?.let { return Resolved(center(it), "label", n.ref) } }
        }

        // 3. Fall back to view-tree frames, using the same node precedence.
        val node = nodeFor(selector)
        node?.frame?.let { return Resolved(center(it), "view", node.ref) }
        return null
    }

    /**
     * The single visible node whose text / a11y label matches, for framework
     * controls with no id of their own (a `Spinner`'s rows, `PopupMenu` items,
     * alert buttons — captured, but sharing one resource id like `text1`).
     *
     * Two rules keep it deterministic rather than "close enough":
     *   - exact match first, substring only if nothing matched exactly;
     *   - ambiguity THROWS. Silently taking the first of several matches is how a
     *     tap lands on the wrong row while looking like it worked.
     *
     * Scoped to the topmost window, so a menu item wins over identical text left
     * behind on the screen underneath it.
     */
    private fun labelMatch(label: String): Node? {
        val candidates = inHighestWindowWithAny(
            documentOrder().filter { it.isVisible && it.frame != null }
        )
        fun textOf(node: Node) = node.text ?: node.contentDescription
        val exact = candidates.filter { textOf(it)?.trim() == label }
        val matches = exact.ifEmpty {
            candidates.filter { textOf(it)?.contains(label, ignoreCase = true) == true }
        }
        // Nested duplicates are not an ambiguity: a row container repeats its
        // child's text, and an alert button wraps a label with the same string at
        // (almost) the same point. Drop any match that is an ANCESTOR of another
        // and keep the innermost. Two matches in DIFFERENT subtrees stay ambiguous
        // — that is the case worth refusing.
        val leaves = matches.filter { node -> matches.none { isAncestor(node, it) } }
        return when {
            leaves.isEmpty() -> null
            leaves.size == 1 -> leaves.first()
            else -> throw CliError(
                "label '$label' matched ${leaves.size} visible nodes " +
                    leaves.take(6).joinToString(", ") { n ->
                        "'${n.text ?: n.contentDescription}' at ${n.frame?.let { f -> "${f.x.toInt()},${f.y.toInt()}" }} (${n.ref})"
                    } +
                    ". Refusing to guess — narrow it with --test-id / --resource-id / --ref, or use --point."
            )
        }
    }

    /**
     * Every node in document order (DFS from the root, then unreached refs
     * sorted). Label matching iterates this rather than the node map so that when
     * two candidates tie, both platforms report the same one — the same reason
     * `Snapshot.firstNode` exists.
     */
    private fun documentOrder(): List<Node> {
        val out = ArrayList<Node>(snapshot.nodes.size)
        val seen = HashSet<String>()
        fun visit(ref: String) {
            if (!seen.add(ref)) return
            val node = snapshot.nodes[ref] ?: return
            out.add(node)
            node.children.forEach(::visit)
        }
        visit(snapshot.rootRef)
        snapshot.nodes.keys.sorted().forEach(::visit)
        return out
    }

    /** Is [candidate] a proper ancestor of [node]? */
    private fun isAncestor(candidate: Node, node: Node): Boolean {
        var current = node.parentRef?.let { snapshot.nodes[it] }
        while (current != null) {
            if (current.ref == candidate.ref) return true
            current = current.parentRef?.let { snapshot.nodes[it] }
        }
        return false
    }

    /**
     * Keep only the candidates that live in the HIGHEST-stacked window containing
     * any of them. A popup's item must win over the same words left on the screen
     * behind it — but "topmost window" alone is the wrong rule: the system keyboard
     * is itself a window in the scene on iOS, so hard-scoping to the top window
     * would hide the app's own content whenever the keyboard is up. Preferring the
     * highest window that HAS a match gives the popup precedence without ever
     * emptying the candidate set.
     */
    private fun inHighestWindowWithAny(nodes: List<Node>): List<Node> {
        val windowRefs = snapshot.root()?.children
            ?.filter { snapshot.nodes[it]?.kind == dev.reticle.core.NodeKind.window }
            ?: return nodes
        if (windowRefs.isEmpty()) return nodes
        val byWindow = nodes.groupBy { windowRefOf(it) }
        for (ref in windowRefs.asReversed()) {
            byWindow[ref]?.takeIf { it.isNotEmpty() }?.let { return it }
        }
        return nodes
    }

    private fun windowRefOf(node: Node): String? {
        var current: Node? = node
        while (current != null) {
            if (current.kind == dev.reticle.core.NodeKind.window) return current.ref
            current = current.parentRef?.let { snapshot.nodes[it] }
        }
        return null
    }

    /**
     * Resolve a sub-region inside [node]. Order:
     *   1. a discovered region (span / virtual a11y) whose label contains the
     *      requested substring, case-insensitively — most reliable, real hit-rect.
     *      (Case-insensitive because a11y labels are often case-normalized by the
     *      platform.)
     *   2. a discovered region whose SOURCE is named: `--region touchDelegate`.
     *      Some channels are rect-only by nature (a touch delegate's forwarded
     *      rect has no in-process target identity), so a label match can never
     *      address them.
     *   3. the char grid: locate the substring's character range and compute its
     *      rect — works even when no region was discoverable (self-drawn). Matched
     *      VERBATIM, not case-folded: the grid maps on-screen text in any language
     *      and case-folding rules are locale-dependent.
     *
     * A needle that matches none of the three **throws**. It used to fall through
     * to a whole-node tap, which is the worst possible answer: on an agreement row
     * the node's centre toggles the checkbox instead of opening the terms, so the
     * caller got a successful-looking tap on a different target.
     */
    private fun resolveRegion(node: Node, needle: String): Resolved {
        // 1. Discovered region by label match.
        node.regions
            .firstOrNull { it.label?.contains(needle, ignoreCase = true) == true }
            ?.let { region ->
                region.tapPoint()?.let { return Resolved(it, "region:${region.source}", node.ref) }
            }

        // 2. Region by source name, for channels that carry no label.
        node.regions
            .firstOrNull { it.source.name.equals(needle, ignoreCase = true) }
            ?.let { region ->
                region.tapPoint()?.let { return Resolved(it, "region:${region.source}", node.ref) }
            }

        // 3. Char grid substring.
        node.charGrid?.let { grid ->
            val idx = grid.text.indexOf(needle)
            if (idx >= 0) {
                val rects = grid.rangeRects(idx, idx + needle.length)
                rects.firstOrNull()?.let {
                    val approxNote = if (grid.approximate) ":approx" else ""
                    return Resolved(Point(it.centerX, it.centerY), "charGrid$approxNote", node.ref)
                }
            }
        }
        throw RegionMissError(
            "node ${node.ref} matched but no region or on-screen text matched '$needle' " +
                "(${node.regions.size} discovered region(s), " +
                "charGrid=${if (node.charGrid != null) "yes" else "no"}). " +
                "Refusing to tap the whole node instead — that would hit a different target. " +
                "List what IS addressable with `ui regions`."
        )
    }

    /**
     * The view-tree node a selector points at. ONE precedence order, shared by the
     * whole-node and the `--region` paths: this used to try `ref` first, so
     * `--test-id X --ref Y` picked a different node depending on whether
     * `--region` was also passed.
     */
    private fun nodeFor(selector: Selector): Node? = when {
        selector.testId != null -> snapshot.firstNode { it.testId == selector.testId }
        selector.resourceId != null -> snapshot.firstNode { it.resourceId == selector.resourceId }
        selector.cssSelector != null -> selector.cssSelector?.let(::nodeByCssSelector)
        selector.ref != null -> snapshot.nodes[selector.ref]
        selector.label != null -> labelMatch(selector.label!!)
        else -> null
    }

    private fun center(rect: Rect) = Point(rect.centerX, rect.centerY)

    private fun nodeByCssSelector(cssSelector: String): Node? =
        snapshot.firstNode { it.domCssSelector() == cssSelector }
}
