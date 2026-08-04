package dev.reticle.cli

import dev.reticle.cli.platform.DeviceController
import dev.reticle.core.ScreenCoverage
import dev.reticle.core.Snapshot
import kotlinx.serialization.json.JsonObject

/**
 * The coverage verdict a coordinate tap carries: was a selector available here,
 * and if not, which named boundary made pixels the only path.
 *
 * Why this runs at all, on the one gesture whose whole point is to skip
 * resolution: `--point` was the silent fallback. Measured over one hybrid-app
 * onboarding flow, 23 of ~50 taps were coordinates and not one of the results said
 * so — so the gaps that forced them could only be found by driving the flow by
 * hand and noticing. A verdict here turns each of those into either a filed gap
 * (naming the boundary) or a correction (naming the flag that would have worked).
 *
 * [before] is the trace's own pre-action capture, reused when tracing is on — which
 * it is by default — so the common path costs no extra tree read. Without it one
 * snapshot is fetched, and a failure to fetch is REPORTED
 * ([ScreenCoverage.REASON_UNAVAILABLE]) rather than dropped: an absent verdict
 * would read as "the coordinate was fine".
 */
internal fun pointCoverage(
    device: DeviceController,
    pkg: String,
    params: JsonObject,
    before: Snapshot?,
    x: Double,
    y: Double,
): JsonObject {
    val snapshot = before ?: runCatching {
        val client = runtimeClientFor(device, pkg, params)
        assertHealthy(client, pkg)
        client.snapshot()
    }.getOrElse { error ->
        return ScreenCoverage.unavailable(
            x, y,
            "the tree could not be read at dispatch time (${error.message ?: error::class.simpleName})",
        ).wire()
    }
    return ScreenCoverage.at(snapshot, x, y).wire()
}
