package dev.reticle.cli

import dev.reticle.core.MetadataValue
import dev.reticle.core.ReticleJson
import dev.reticle.core.Selector
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** Shared JSON and selector parsing helpers for the stdio helper RPC surface. */
internal fun okResponse(id: Int, result: JsonElement): String =
    ReticleJson.compact.encodeToString(
        JsonElement.serializer(),
        buildJsonObject {
            put("id", id)
            put("ok", true)
            put("result", result)
        }
    )

internal fun errorResponse(id: Int, message: String): String =
    ReticleJson.compact.encodeToString(
        JsonElement.serializer(),
        buildJsonObject {
            put("id", id)
            put("ok", false)
            put("error", message)
        }
    )

internal fun JsonObject.str(key: String): String? = this[key]?.jsonPrimitive?.contentOrNull

internal fun JsonObject.intOrNull(key: String): Int? = str(key)?.toIntOrNull()

internal fun selectorFrom(params: JsonObject): Selector = Selector(
    testId = params.str("testId"),
    resourceId = params.str("resourceId"),
    cssSelector = params.str("css") ?: params.str("cssSelector"),
    ref = params.str("ref"),
    point = params.str("point")?.let {
        val (x, y) = parseXY(it)
        dev.reticle.core.Point(x.toDouble(), y.toDouble())
    },
    region = params.str("region"),
)

internal fun parseXY(value: String): Pair<Int, Int> {
    val parts = value.split(",")
    if (parts.size != 2) throw CliError("expected x,y but got '$value'")
    return parts[0].trim().toInt() to parts[1].trim().toInt()
}

internal fun parseValue(raw: String): MetadataValue = when {
    raw == "true" || raw == "false" -> MetadataValue.Bool(raw.toBoolean())
    raw.toLongOrNull() != null -> MetadataValue.Integer(raw.toLong())
    raw.toDoubleOrNull() != null -> MetadataValue.Real(raw.toDouble())
    else -> MetadataValue.Text(raw)
}
