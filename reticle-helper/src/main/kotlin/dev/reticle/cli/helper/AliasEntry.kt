package dev.reticle.cli

import dev.reticle.core.Rect
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/**
 * One `@N` outline entry, as the host resolved it from its alias cache.
 *
 * `ui outline` and the cache live in the Swift host now (`Outline` /
 * `OutlineAliasCache`); `act --alias @N` arrives here with the cached entry as the
 * `aliasEntry` param, and the helper only re-finds it in the live tree
 * ([aliasLiveMatch]) because that needs the device.
 */
internal data class AliasEntry(
    val ref: String,
    val role: String,
    val label: String?,
    val frame: Rect,
    val testId: String?,
    val resourceId: String?,
    val css: String?,
) {
    companion object {
        fun from(params: JsonObject, alias: String): AliasEntry {
            val item = params["aliasEntry"] as? JsonObject
                ?: throw CliError("--alias $alias reached the helper without its resolved outline entry; the host resolves aliases — upgrade reticle")
            fun bad(detail: String) = CliError("outline entry for $alias is malformed ($detail)")
            fun opt(key: String): String? = (item[key] as? JsonPrimitive)?.contentOrNull
            val frame = item["frame"] as? JsonObject ?: throw bad("missing 'frame'")
            fun num(key: String): Double =
                (frame[key] as? JsonPrimitive)?.contentOrNull?.toDoubleOrNull() ?: throw bad("frame.$key is not a number")
            return AliasEntry(
                ref = opt("ref") ?: throw bad("missing 'ref'"),
                role = opt("role") ?: throw bad("missing 'role'"),
                label = opt("label"),
                frame = Rect(x = num("x"), y = num("y"), width = num("width"), height = num("height")),
                testId = opt("testId"),
                resourceId = opt("resourceId"),
                css = opt("css"),
            )
        }
    }
}
