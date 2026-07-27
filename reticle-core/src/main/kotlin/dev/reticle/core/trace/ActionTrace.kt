package dev.reticle.core.trace

import dev.reticle.core.MetadataValue
import dev.reticle.core.Node
import dev.reticle.core.Point
import dev.reticle.core.Rect
import dev.reticle.core.Selector
import dev.reticle.core.Snapshot
import kotlinx.serialization.Serializable

/**
 * Evidence package manifest for one dispatched action.
 *
 * Large artifacts stay beside this manifest on disk and are referenced by
 * relative path, so the same shape can later be streamed through the daemon
 * event bus without inlining snapshots or screenshots into every event.
 */
@Serializable
data class ActionTrace(
    val traceVersion: Int = 1,
    val actionId: String,
    val packageName: String,
    /**
     * Source platform ("android" / "ios"), copied from the captured snapshot so
     * a trace manifest is self-describing across platforms — the iOS writer
     * (`IosActionTrace`) already emits this, and consumers (replay, the panel)
     * read one shape. Defaulted so older/direct callers stay wire-compatible;
     * the helper always populates it, so it is emitted in practice.
     */
    val platform: String = "",
    val recordedAtMillis: Long,
    val gesture: String,
    /**
     * The inputs that SHAPED this gesture, as the caller gave them — the typed
     * text, `submit`, `settle`, a swipe's `from`/`to`/`duration`, the verify
     * predicate.
     *
     * Distinct from [result], which is what the dispatch reported back. Without
     * this a `type` trace records `chars: 6` and no reader can ever say what was
     * typed; the selector says where, the result says it happened, and nothing
     * said what. Populated from an explicit allow-list ([ActionTraceParams]), so
     * transport and bookkeeping keys — serial, traceOutput, package — never leak
     * into the evidence package.
     */
    val params: Map<String, String> = emptyMap(),
    val selector: Selector? = null,
    val target: ActionTraceTarget? = null,
    val result: Map<String, String> = emptyMap(),
    val artifacts: ActionTraceArtifacts,
    val diff: List<ActionTraceChange> = emptyList(),
)

/**
 * Which request keys are gesture inputs worth recording in [ActionTrace.params].
 *
 * An allow-list rather than a block-list: a new transport or bookkeeping key
 * added to the RPC should default to NOT being written into every evidence
 * package on disk. Both the Kotlin helper and the Swift iOS writer read this
 * same list of names.
 *
 * Note what this means for `text`: a `type` action's text is recorded verbatim.
 * That is the point — "what did it type" is unanswerable otherwise — but nothing
 * in the capture layer marks a field as secure, so Reticle cannot know a
 * password from a coupon code and does not pretend to. See docs/boundaries.md.
 */
object ActionTraceParams {
    val RECORDED: List<String> = listOf(
        // type
        "text", "submit",
        // tap
        "settle", "settleTimeoutMs",
        // swipe / drag
        "from", "to", "duration",
        // scroll-to
        "container", "direction", "maxSwipes",
        // verify (the weak "did anything change" watch, not an assertion)
        "verify", "verifyTimeoutMs",
        // wait
        "for", "gone", "idle", "textContains", "timeoutMs", "quietMs",
    )
}

/** Targeting evidence for actions that resolve to a concrete screen point. */
@Serializable
data class ActionTraceTarget(
    val point: Point? = null,
    val source: String? = null,
    val ref: String? = null,
)

/** Relative artifact paths inside an action trace directory. */
@Serializable
data class ActionTraceArtifacts(
    val beforeSnapshot: String,
    val afterSnapshot: String,
    val beforeScreenshot: String? = null,
    val afterScreenshot: String? = null,
)

/** One compact before/after fact extracted from two snapshots. */
@Serializable
data class ActionTraceChange(
    val ref: String? = null,
    val field: String,
    val before: String? = null,
    val after: String? = null,
    /**
     * Who [ref] is, attached to the FIRST change listed for that ref.
     *
     * Without it a change reads `r102.present false -> true`, and the only place
     * that says what r102 was is the 100KB+ snapshot sitting beside the manifest.
     * Identity is read from whichever side the node exists on — `after` for an
     * appearance, `before` for a disappearance — so a node that vanished is still
     * named. Repeats are suppressed per ref: three fields changing on one node
     * name it once, not three times.
     */
    val node: ActionTraceNodeIdentity? = null,
    /** Free-form detail. Only the `truncated` marker carries one today. */
    val note: String? = null,
)

/**
 * Enough of a node to recognise it without opening the snapshot.
 *
 * Deliberately not a selector: `role`/`text` are descriptive, and a `ref` is only
 * valid inside the snapshot that produced it. This names the thing that changed;
 * it does not promise you can address it again later.
 */
@Serializable
data class ActionTraceNodeIdentity(
    val testId: String? = null,
    val resourceId: String? = null,
    val label: String? = null,
    val role: String? = null,
    /**
     * Only populated when the node has no testId/resourceId/label — i.e. when its
     * text is the only handle a reader has on it. Clipped to
     * [ActionTraceDiff.IDENTITY_TEXT_LIMIT]; the untruncated value is in the
     * snapshot, and in `before`/`after` when the text itself is what changed.
     */
    val text: String? = null,
)

/** Pure snapshot diffing for action traces; intentionally compact and bounded. */
object ActionTraceDiff {
    /** Longest node text carried as identity before clipping. */
    const val IDENTITY_TEXT_LIMIT = 60

    /**
     * How much a field says about what an action DID, lowest rank listed first.
     *
     * Ordering is not cosmetic: the list is capped, so whatever sorts last is what
     * gets dropped. Ranking by field means a cap spends its budget on appearances
     * and text changes, and sheds pixel-level `frame` churn — the previous
     * alphabetical-by-ref order could spend all 100 slots on the frames of a
     * scrolling list and truncate away the one node that appeared.
     */
    private fun fieldRank(field: String): Int = when (field) {
        // A node appearing or disappearing is the strongest evidence an action landed.
        "present" -> 0
        // What the user would see change.
        "text", "label", "enabled", "visible" -> 1
        // Identity and affordance: rarer, and meaningful when they do move.
        "testId", "resourceId", "role", "kind", "interactive", "regions" -> 2
        // Geometry, structure, counts, and custom.* — the noisy tail. Animation
        // and scrolling produce these by the hundred without an action landing.
        else -> 3
    }

    /**
     * How addressable the changed node is, lowest listed first.
     *
     * The second half of ranking, and it is not a nicety. A screen transition
     * makes hundreds of nodes appear at once, and by field rank alone they tie —
     * so the cap filled with whatever the ref order happened to hit first, which
     * on a SwiftUI or Compose screen is layout scaffolding. Six lines of
     * `+ r104 [role=container]` describe nothing. A node carrying a testId is
     * both the likelier subject of the action and the only one a reader can do
     * anything with afterwards.
     */
    private fun identityRank(node: Node?): Int = when {
        // A ref-less change (nodeCount) is not an unaddressable node — it is not
        // about a node at all. Ranking a whole-screen summary by "how addressable
        // is it" is a category error, and ranking it LAST let one line of genuine
        // context get truncated away in favour of a container's child list.
        node == null -> 0
        node.testId != null || node.resourceId != null -> 0
        node.contentDescription != null || node.text != null -> 1
        else -> 2
    }

    private data class Ranked(val change: ActionTraceChange, val identityRank: Int)

    fun compare(before: Snapshot, after: Snapshot, maxChanges: Int = 100): List<ActionTraceChange> {
        val found = ArrayList<Ranked>()
        fun add(ref: String?, field: String, old: String?, new: String?) {
            if (old == new) return
            val node = if (ref == null) null else after.nodes[ref] ?: before.nodes[ref]
            found.add(
                Ranked(
                    ActionTraceChange(ref = ref, field = field, before = old, after = new),
                    identityRank(node),
                )
            )
        }

        add(null, "nodeCount", before.nodes.size.toString(), after.nodes.size.toString())
        val refs = (before.nodes.keys + after.nodes.keys).sorted()
        for (ref in refs) {
            val b = before.nodes[ref]
            val a = after.nodes[ref]
            when {
                b == null && a != null -> add(ref, "present", "false", "true")
                b != null && a == null -> add(ref, "present", "true", "false")
                b != null && a != null -> compareNode(ref, b, a, ::add)
            }
        }

        // Rank first, then cap: by field, then by how addressable the node is,
        // then by traversal order. `withIndex`/`sortedWith` keeps traversal order
        // inside a rank, so the result stays deterministic for the shared fixture.
        val ranked = found.withIndex()
            .sortedWith(
                compareBy(
                    { fieldRank(it.value.change.field) },
                    { it.value.identityRank },
                    { it.index },
                )
            )
            .map { it.value.change }
        val kept = ranked.take(maxChanges)
        val dropped = ranked.drop(maxChanges)

        // Name each ref once, on its first surviving change, so three fields moving
        // on one node cost one identity rather than three.
        val named = HashSet<String>()
        val out = ArrayList<ActionTraceChange>(kept.size + 1)
        for (change in kept) {
            val ref = change.ref
            if (ref == null || !named.add(ref)) {
                out.add(change)
                continue
            }
            out.add(change.copy(node = identity(after.nodes[ref] ?: before.nodes[ref])))
        }
        if (dropped.isNotEmpty()) {
            // Say what was dropped, not just how much. "truncated: 100" reads as
            // "you have the interesting part"; it never was a safe thing to assume.
            out.add(
                ActionTraceChange(
                    field = "truncated",
                    before = found.size.toString(),
                    after = kept.size.toString(),
                    note = "dropped by field: " + droppedSummary(dropped),
                )
            )
        }
        return out
    }

    /** `frame 96, children 31, custom.badge 4` — the heaviest field names first. */
    private fun droppedSummary(dropped: List<ActionTraceChange>, maxNames: Int = 6): String {
        val counts = dropped.groupingBy { it.field }.eachCount()
        val ordered = counts.entries.sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
        val shown = ordered.take(maxNames).joinToString(", ") { "${it.key} ${it.value}" }
        val rest = ordered.drop(maxNames)
        if (rest.isEmpty()) return shown
        return "$shown, and ${rest.size} more field(s) totalling ${rest.sumOf { it.value }}"
    }

    private fun identity(node: Node?): ActionTraceNodeIdentity? {
        if (node == null) return null
        val testId = node.testId
        val resourceId = node.resourceId
        val label = node.contentDescription
        val anonymous = testId == null && resourceId == null && label == null
        val text = if (anonymous) node.text?.clipIdentityText() else null
        if (testId == null && resourceId == null && label == null && node.role == null && text == null) return null
        return ActionTraceNodeIdentity(
            testId = testId,
            resourceId = resourceId,
            label = label,
            role = node.role,
            text = text,
        )
    }

    /**
     * Collapse to one line and clip, so identity never breaks a line-oriented
     * reader and never costs more than a glance.
     *
     * Both the whitespace set and the clip unit are spelled out rather than
     * inherited from the platform: Kotlin's `\s` and Swift's `isWhitespace`
     * cover different characters, and `String.take` counts UTF-16 units while
     * Swift's `prefix` counts grapheme clusters. Left to defaults the two ports
     * would agree on ASCII and quietly disagree on CJK, emoji, and NBSP. Clipping
     * is by code point, which is exactly one Unicode scalar on the Swift side.
     */
    private fun String.clipIdentityText(): String? {
        val collapsed = collapseWhitespace()
        if (collapsed.isEmpty()) return null
        val codePoints = collapsed.codePointCount(0, collapsed.length)
        if (codePoints <= IDENTITY_TEXT_LIMIT) return collapsed
        return collapsed.substring(0, collapsed.offsetByCodePoints(0, IDENTITY_TEXT_LIMIT)) + "…"
    }

    /** Java's `\s`, written out so the Swift port can match it exactly. */
    private fun Char.isTraceWhitespace(): Boolean =
        this == ' ' || this == '\t' || this == '\n' || this == '\u000B' || this == '\u000C' || this == '\r'

    private fun String.collapseWhitespace(): String {
        val sb = StringBuilder(length)
        var pendingGap = false
        for (ch in this) {
            if (ch.isTraceWhitespace()) {
                if (sb.isNotEmpty()) pendingGap = true
                continue
            }
            if (pendingGap) {
                sb.append(' ')
                pendingGap = false
            }
            sb.append(ch)
        }
        return sb.toString()
    }

    private fun compareNode(
        ref: String,
        before: Node,
        after: Node,
        add: (String?, String, String?, String?) -> Unit,
    ) {
        add(ref, "kind", before.kind.name, after.kind.name)
        add(ref, "role", before.role, after.role)
        add(ref, "text", before.text, after.text)
        add(ref, "label", before.contentDescription, after.contentDescription)
        add(ref, "testId", before.testId, after.testId)
        add(ref, "resourceId", before.resourceId, after.resourceId)
        add(ref, "frame", before.frame?.traceString(), after.frame?.traceString())
        add(ref, "visible", before.isVisible.toString(), after.isVisible.toString())
        add(ref, "enabled", before.isEnabled.toString(), after.isEnabled.toString())
        add(ref, "interactive", before.isInteractive.toString(), after.isInteractive.toString())
        add(ref, "children", before.children.joinToString(","), after.children.joinToString(","))
        add(ref, "regions", before.regions.size.toString(), after.regions.size.toString())
        val customKeys = (before.custom.keys + after.custom.keys).sorted()
        for (key in customKeys) {
            add(ref, "custom.$key", before.custom[key]?.traceDisplay(), after.custom[key]?.traceDisplay())
        }
    }

    private fun Rect.traceString(): String =
        "${x.toInt()},${y.toInt()} ${width.toInt()}x${height.toInt()}"

    private fun MetadataValue.traceDisplay(): String = displayString()
}
