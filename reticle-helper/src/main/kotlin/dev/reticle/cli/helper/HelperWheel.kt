package dev.reticle.cli

import dev.reticle.core.Node
import dev.reticle.core.Rect
import dev.reticle.core.Snapshot
import dev.reticle.cli.platform.DeviceController
import dev.reticle.cli.platform.InputDispatcher
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * `act wheel`: move a wheel column onto a value, by converging on the wheel's own
 * reading rather than by calibrating pixels.
 *
 * The flow this exists for, measured on a real date picker: the wheel's candidate
 * values are painted onto its canvas, so `--label "1995"` has nothing to resolve and
 * `act scroll-to` can never converge (no selector for an unselected value will ever
 * resolve). What was left was reading the numbers off a screenshot, measuring the row
 * pitch in that image, swiping a hand-derived distance, and screenshotting again to
 * see where it landed — four round-trips for "select 1995".
 *
 * With the wheel publishing its own state ([Node.wheelValue], [Node.wheelIndex],
 * [Node.wheelRowHeightPx]) the loop closes without pixels: aim a swipe at the rows
 * still between here and the target, re-read the value, repeat. The pitch makes the
 * FIRST swipe roughly right; the re-read is what makes the result true, so an
 * estimated pitch costs an extra iteration rather than a wrong answer.
 *
 * What it refuses, by name rather than by silence:
 *  - a wheel that publishes nothing (`wheel:opaque`, a self-drawn/third-party
 *    column): there is no reading to converge on, so a loop here could only report
 *    success it cannot check;
 *  - a value the wheel does not offer, when the label set is known;
 *  - a wheel that stops moving before it arrives — reported with where it stopped,
 *    because "the wheel is at 1994 and will not go further" and "the tool gave up"
 *    are different facts.
 */
internal object HelperWheel {

    /** Swipe budget. A 120-value year wheel needs ~8 at ten rows a swipe. */
    private const val DEFAULT_MAX_SWIPES = 16

    /** Slow, like `scroll-to`: a flick keeps moving after the gesture returns. */
    private const val SWIPE_DURATION_MS = 500

    /** Let the wheel settle and commit before re-reading. */
    private const val SETTLE_MS = 350L

    /**
     * How much of the SCREEN one swipe may travel. The drag starts inside the column
     * — that is what makes the wheel the target — and is free to end outside it: a
     * pointer keeps being tracked by the view that captured it, so a short column can
     * still be moved many rows at a time. Bounded well inside the screen so the
     * gesture cannot be read as an edge swipe (back/notification) by the system.
     *
     * Measured on the sample's hour wheel: bounded by the COLUMN (473px tall, 157px
     * pitch) a swipe moved one row and 09 -> 17 took eight of them; a 120-value year
     * wheel would exhaust any sane budget. Bounded by the screen it moves several.
     */
    private const val TRAVEL_FRACTION = 0.6

    /** Keep the drag this far from the top and bottom edges of the screen. */
    private const val EDGE_MARGIN_PX = 200

    fun run(
        input: InputDispatcher,
        device: DeviceController,
        pkg: String,
        params: JsonObject,
    ): JsonObject {
        val wantedValue = params.str("to")
        val wantedIndex = params.intOrNull("toIndex")
        if (wantedValue == null && wantedIndex == null) {
            throw CliError("act wheel needs a target: --to \"<value>\" (the label the wheel shows) or --to-index <n>")
        }
        val client = runtimeClientFor(device, pkg, params)
        assertHealthy(client, pkg)

        var snapshot = client.snapshot()
        var wheel = resolveWheel(snapshot, params)
        val facts = factsOrRefuse(wheel)
        val target = targetIndex(wheel, facts, wantedValue, wantedIndex)

        val frame = wheel.frame ?: throw CliError("act wheel: ${wheel.ref} has no frame to swipe inside")
        val pitch = wheel.wheelRowHeightPx()?.takeIf { it > 0 }
            ?: throw CliError(
                "act wheel: ${label(wheel)} publishes no row pitch, so a swipe distance cannot be " +
                    "derived. Drive it with `act swipe` and take the app's own committed state as the verdict."
            )
        val travel = maxOf(
            pitch.toDouble(),
            (snapshot.screen.size.height - 2 * EDGE_MARGIN_PX) * TRAVEL_FRACTION,
        )
        val rowsPerSwipe = maxOf(1, (travel / pitch).toInt())

        var current = facts.index
        var swipes = 0
        var stalled = 0
        val from = facts.value
        while (current != target) {
            if (swipes >= DEFAULT_MAX_SWIPES) {
                throw CliError(
                    "act wheel gave up after $swipes swipe(s): ${label(wheel)} is on " +
                        "\"${valueOf(wheel)}\" (index $current) and the target is index $target. " +
                        "Raise the distance by driving it in steps, or check that the wheel is not " +
                        "being re-set by the app between swipes."
                )
            }
            val remaining = target - current
            val rows = minOf(kotlin.math.abs(remaining), rowsPerSwipe)
            swipeRows(input, frame, snapshot.screen.size.height, rows = rows, forward = remaining > 0, pitch = pitch)
            swipes++
            Thread.sleep(SETTLE_MS)

            snapshot = client.snapshot()
            wheel = refind(snapshot, wheel)
                ?: throw CliError("act wheel: ${label(wheel)} left the tree mid-run after $swipes swipe(s)")
            val moved = wheel.wheelIndex()
                ?: throw CliError("act wheel: ${label(wheel)} stopped publishing its index after $swipes swipe(s)")
            if (moved == current) {
                stalled++
                if (stalled >= 2) {
                    throw CliError(
                        "act wheel: ${label(wheel)} did not move on the last $stalled swipe(s) and is " +
                            "still on \"${valueOf(wheel)}\" (index $current of ${facts.min}..${facts.max}). " +
                            "It is at its end, or the app is holding it there — this is where the wheel " +
                            "is, not a tool timeout."
                    )
                }
            } else {
                stalled = 0
            }
            current = moved
        }

        return buildJsonObject {
            put("gesture", "wheel")
            put("ref", wheel.ref)
            put("from", from)
            put("value", valueOf(wheel))
            put("index", current)
            put("swipes", swipes)
            put("rowsPerSwipe", rowsPerSwipe)
            put("pitchPx", pitch)
            // An estimated pitch means the first swipe was a guess that the re-read
            // corrected; say so, since it explains an extra swipe in the count.
            if (wheel.wheelRowHeightEstimated()) put("pitchEstimated", true)
        }
    }

    /** The wheel's published state, or a refusal naming why there is none. */
    private data class Facts(val value: String, val index: Int, val min: Int, val max: Int)

    private fun factsOrRefuse(wheel: Node): Facts {
        val value = wheel.wheelValue()
        val index = wheel.wheelIndex()
        val min = wheel.wheelMin()
        val max = wheel.wheelMax()
        if (value == null || index == null || min == null || max == null) {
            throw CliError(
                "act wheel needs a wheel that publishes its own value, and ${label(wheel)} publishes " +
                    "none (`wheel:opaque` — a self-drawn column paints every value onto its canvas and " +
                    "exposes no adapter). There is nothing to converge on, so this would report a " +
                    "success it cannot check. Drive it with `act swipe` along the column and take the " +
                    "app's own committed state as the verdict."
            )
        }
        return Facts(value, index, min, max)
    }

    /** Which index the caller asked for, refusing a value the wheel does not offer. */
    private fun targetIndex(wheel: Node, facts: Facts, wantedValue: String?, wantedIndex: Int?): Int {
        if (wantedIndex != null) {
            if (wantedIndex < facts.min || wantedIndex > facts.max) {
                throw CliError(
                    "act wheel --to-index $wantedIndex is outside the range of ${label(wheel)}, " +
                        "which is ${facts.min}..${facts.max}."
                )
            }
            return wantedIndex
        }
        val wanted = wantedValue!!
        val items = wheel.wheelItems()
        if (items.isEmpty()) {
            throw CliError(
                "act wheel --to \"$wanted\": ${label(wheel)} publishes no item labels, so a value " +
                    "cannot be turned into a position. Use --to-index <n> (its range is " +
                    "${facts.min}..${facts.max}, currently ${facts.index} = \"${facts.value}\")."
            )
        }
        val exact = items.indexOfFirst { it == wanted }
        val position = if (exact >= 0) exact else items.indexOfFirst { it.equals(wanted, ignoreCase = true) }
        if (position < 0) {
            val truncated = wheel.wheelItemsTruncated()
            val tail = if (truncated != null) {
                " The capture carries only the first ${items.size} of ${items.size + truncated} labels, " +
                    "so the value may be further down — use --to-index."
            } else {
                " It offers: ${items.take(12).joinToString(", ")}${if (items.size > 12) ", …" else ""}."
            }
            throw CliError("act wheel: ${label(wheel)} has no value \"$wanted\".$tail")
        }
        return facts.min + position
    }

    /**
     * Move `rows` values. Positive [forward] means towards a HIGHER index, which on a
     * wheel means dragging UP the column — the values scroll the way the finger goes.
     */
    private fun swipeRows(
        input: InputDispatcher,
        frame: Rect,
        screenHeight: Double,
        rows: Int,
        forward: Boolean,
        pitch: Int,
    ) {
        val cx = frame.centerX.toInt()
        val distance = rows * pitch
        val cy = frame.centerY.toInt()
        val half = distance / 2
        // The START must be inside the column — that is what makes this wheel the
        // target — while the END may leave it: the view that captured the pointer
        // keeps receiving the move events, which is what lets a 473px column travel
        // further than 473px in one gesture.
        val insideTop = frame.y.toInt() + 1
        val insideBottom = (frame.y + frame.height).toInt() - 1
        val screenTop = EDGE_MARGIN_PX
        val screenBottom = (screenHeight - EDGE_MARGIN_PX).toInt()
        val (rawFrom, rawTo) = if (forward) (cy + half) to (cy - half) else (cy - half) to (cy + half)
        input.swipe(
            cx, rawFrom.coerceIn(insideTop, insideBottom),
            cx, rawTo.coerceIn(screenTop, screenBottom),
            SWIPE_DURATION_MS,
        )
    }

    /** Refs are per-capture; re-find the wheel the way the read-back paths do. */
    private fun refind(snapshot: Snapshot, wheel: Node): Node? {
        wheel.testId?.let { id ->
            snapshot.nodes.values.filter { it.testId == id }.singleOrNull()?.let { return it }
        }
        wheel.resourceId?.let { id ->
            snapshot.nodes.values.filter { it.resourceId == id && it.suspectedWheel }.singleOrNull()
                ?.let { return it }
        }
        val frame = wheel.frame
        if (frame != null) {
            snapshot.nodes.values.firstOrNull {
                it.suspectedWheel && it.frame?.x == frame.x && it.frame?.y == frame.y
            }?.let { return it }
        }
        return snapshot.nodes[wheel.ref]?.takeIf { it.suspectedWheel }
    }

    private fun resolveWheel(snapshot: Snapshot, params: JsonObject): Node {
        val selector = selectorFrom(params)
        // Resolve the way every other gesture does, then take the NODE: the resolver
        // answers with a point, and a wheel is addressed as a whole column.
        val resolved = dev.reticle.core.SelectorResolver(
            snapshot, dev.reticle.core.SemanticTree.build(snapshot),
        ).resolve(selector) ?: throw CliError(SelectorDiagnostics.nodeMiss(snapshot, selector))
        val node = resolved.ref?.let { snapshot.nodes[it] }
            ?: throw CliError(
                "act wheel resolved '${selector.describe()}' to a point but not to a node, so there is " +
                    "no wheel to read. Name the column itself (--test-id / --resource-id)."
            )
        if (!node.suspectedWheel) {
            throw CliError(
                "act wheel: ${label(node)} is not a wheel column (no wheel marker in `ui compact`). " +
                    "For a dropdown use `act tap` on the row; for a list use `act scroll-to`."
            )
        }
        return node
    }

    private fun valueOf(wheel: Node): String = wheel.wheelValue() ?: "?"

    private fun label(node: Node): String = "'${node.testId ?: node.resourceId ?: node.ref}'"
}
