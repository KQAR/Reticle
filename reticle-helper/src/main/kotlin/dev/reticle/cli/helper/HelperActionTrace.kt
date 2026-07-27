package dev.reticle.cli

import dev.reticle.core.ReticleJson
import dev.reticle.core.Selector
import dev.reticle.core.Snapshot
import dev.reticle.core.trace.ActionTrace
import dev.reticle.core.trace.ActionTraceArtifacts
import dev.reticle.core.trace.ActionTraceDiff
import dev.reticle.core.trace.ActionTraceParams
import dev.reticle.core.trace.ActionTraceTarget
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.io.File

/** Writes the per-action evidence package used by action traces. */
internal class HelperActionTrace private constructor(
    private val root: File,
    private val packageName: String,
    private val client: RuntimeClient,
    /**
     * The gesture-shaping inputs, captured at construction from the RPC request.
     * Held here rather than passed to [write] because by write time the request
     * has already been reduced to a result, which is exactly how `type` ended up
     * recording `chars: 6` and never the text.
     */
    private val recordedParams: Map<String, String>,
) {
    data class Capture(val snapshot: Snapshot, val screenshotPng: ByteArray?)

    fun capture(): Capture = Capture(
        snapshot = client.snapshot(),
        screenshotPng = runCatching { client.screenshotBytes() }.getOrNull(),
    )

    fun write(
        gesture: String,
        selector: Selector?,
        target: ResolvedInputTarget?,
        result: JsonObject,
        before: Capture,
        settleMillis: Long,
    ): JsonObject {
        if (settleMillis > 0) Thread.sleep(settleMillis)
        val after = capture()
        val actionId = "${System.currentTimeMillis()}-$gesture"
        val dir = uniqueTraceDir(actionId)

        val beforeSnapshot = "before.snapshot.json"
        val afterSnapshot = "after.snapshot.json"
        val beforeScreenshot = before.screenshotPng?.let { "before.screenshot.png" }
        val afterScreenshot = after.screenshotPng?.let { "after.screenshot.png" }

        File(dir, beforeSnapshot).writeText(
            ReticleJson.instance.encodeToString(Snapshot.serializer(), before.snapshot)
        )
        File(dir, afterSnapshot).writeText(
            ReticleJson.instance.encodeToString(Snapshot.serializer(), after.snapshot)
        )
        beforeScreenshot?.let { File(dir, it).writeBytes(before.screenshotPng!!) }
        afterScreenshot?.let { File(dir, it).writeBytes(after.screenshotPng!!) }

        val trace = ActionTrace(
            actionId = actionId,
            packageName = packageName,
            // Self-describe the source platform, mirroring the iOS trace writer.
            // The Android agent always stamps snapshot.platform; fall back
            // defensively so the field is never blank.
            platform = before.snapshot.platform.ifEmpty { "android" },
            recordedAtMillis = System.currentTimeMillis(),
            gesture = gesture,
            params = recordedParams,
            selector = selector,
            target = target?.let {
                ActionTraceTarget(point = it.point, source = it.source, ref = it.ref)
            },
            result = result.scalarMap(),
            artifacts = ActionTraceArtifacts(
                beforeSnapshot = beforeSnapshot,
                afterSnapshot = afterSnapshot,
                beforeScreenshot = beforeScreenshot,
                afterScreenshot = afterScreenshot,
            ),
            diff = ActionTraceDiff.compare(before.snapshot, after.snapshot),
        )
        File(dir, "trace.json").writeText(ReticleJson.instance.encodeToString(ActionTrace.serializer(), trace))

        return buildJsonObject {
            put("actionId", actionId)
            put("path", dir.absolutePath)
            put("changeCount", trace.diff.size)
            put("beforeSnapshot", beforeSnapshot)
            put("afterSnapshot", afterSnapshot)
            beforeScreenshot?.let { put("beforeScreenshot", it) }
            afterScreenshot?.let { put("afterScreenshot", it) }
            put("manifest", "trace.json")
        }
    }

    private fun uniqueTraceDir(actionId: String): File {
        if (root.exists() && !root.isDirectory) throw CliError("traceOutput is not a directory: ${root.absolutePath}")
        root.mkdirs()
        var candidate = File(root, actionId)
        var suffix = 2
        while (candidate.exists()) {
            candidate = File(root, "$actionId-$suffix")
            suffix += 1
        }
        if (!candidate.mkdirs()) throw CliError("could not create trace directory: ${candidate.absolutePath}")
        return candidate
    }

    companion object {
        fun from(params: JsonObject, packageName: String, client: RuntimeClient?): HelperActionTrace? {
            val output = params.str("traceOutput") ?: return null
            val runtimeClient = client ?: throw CliError("trace capture needs a runtime client")
            return HelperActionTrace(
                File(output).absoluteFile,
                packageName,
                runtimeClient,
                recordedParams = params.recordedGestureParams(),
            )
        }
    }
}

internal fun selectorOrNull(params: JsonObject): Selector? {
    val sel = selectorFrom(params)
    val empty = sel.testId == null &&
        sel.resourceId == null &&
        sel.cssSelector == null &&
        sel.ref == null &&
        sel.point == null &&
        sel.region == null
    return if (empty) null else sel
}

private fun JsonObject.scalarMap(): Map<String, String> =
    entries.associate { (key, value) -> key to value.traceString() }

/**
 * The gesture inputs from an act request, in [ActionTraceParams.RECORDED] order
 * so two traces of the same gesture read the same way. Absent keys are skipped
 * rather than written as null — a manifest should not carry a field per gesture
 * the action was not.
 */
private fun JsonObject.recordedGestureParams(): Map<String, String> {
    val out = LinkedHashMap<String, String>()
    for (key in ActionTraceParams.RECORDED) {
        val value = this[key] ?: continue
        if (value is JsonNull) continue
        out[key] = value.traceString()
    }
    return out
}

private fun JsonElement.traceString(): String =
    (this as? JsonPrimitive)?.jsonPrimitive?.contentOrNull ?: toString()
