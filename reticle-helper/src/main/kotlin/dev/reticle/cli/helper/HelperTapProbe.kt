package dev.reticle.cli

import dev.reticle.cli.platform.DeviceController
import dev.reticle.core.ReticleJson
import dev.reticle.core.Snapshot
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * The tree a tap was dispatched against, handed to the host so it can judge the tap.
 *
 * Two verdicts ride on every tap and are computed in the host by
 * `ReticleProtocol.ScreenCoverage` (the only implementation, shared with iOS):
 * `coverage` for a raw `--point` (was a selector available here, or which named
 * boundary made pixels the only path) and `obstruction` for every tap (who receives
 * the touch instead of the target). Both must be judged BEFORE the touch — after it
 * the screen this coordinate was aimed at may not exist any more — which is why the
 * helper captures and the host only reads.
 *
 * [before] is the trace's own pre-action capture, reused when tracing is on — which
 * it is by default — so the common path costs no extra tree read. Without it one
 * snapshot is fetched; a failure to fetch is carried as `error` rather than dropped,
 * because the host reports it as `coverage:unavailable` for a coordinate tap: an
 * absent verdict would read as "the coordinate was fine".
 *
 * Wire shape (`tapProbe` on the act result, stripped by the host before printing):
 * `{ "x", "y", "point": bool, "snapshot": <Snapshot> }` or `{ "x", "y", "point", "error" }`.
 */
internal fun tapProbe(
    device: DeviceController,
    pkg: String,
    params: JsonObject,
    before: Snapshot?,
    x: Double,
    y: Double,
    rawPoint: Boolean,
): JsonObject {
    val snapshot = before ?: runCatching {
        val client = runtimeClientFor(device, pkg, params)
        assertHealthy(client, pkg)
        client.snapshot()
    }.getOrElse { error ->
        return buildJsonObject {
            put("x", x)
            put("y", y)
            put("point", rawPoint)
            put(
                "error",
                "the tree could not be read at dispatch time (${error.message ?: error::class.simpleName})",
            )
        }
    }
    return buildJsonObject {
        put("x", x)
        put("y", y)
        put("point", rawPoint)
        put("snapshot", ReticleJson.compact.encodeToJsonElement(Snapshot.serializer(), snapshot))
    }
}
