package dev.reticle.cli

import dev.reticle.core.Selector
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** Support for `act --verify`: watch one node before and after a gesture. */
internal object HelperVerify {
    fun watchSelectorFrom(params: JsonObject): Selector? {
        val token = params["verify"]?.jsonPrimitive?.content ?: return null
        if (token == "true") {
            val sel = selectorFrom(params)
            return parseVerifyToken("true", sel.testId, sel.resourceId, sel.cssSelector, sel.ref)
        }
        return parseVerifyToken(token, null, null, null, null)
    }

    fun captureState(client: RuntimeClient, sel: Selector): VerifyState {
        val node = findNode(client.snapshot(), selectorParams(sel))
            ?: return VerifyState(false, null, null, false, false, null, emptyMap())
        return VerifyState(
            found = true,
            text = node.text,
            label = node.contentDescription,
            enabled = node.isEnabled,
            visible = node.isVisible,
            frame = node.frame?.let { "${it.x.toInt()},${it.y.toInt()} ${it.width.toInt()}x${it.height.toInt()}" },
            custom = node.custom.mapValues { it.value.displayString() },
        )
    }

    fun pollForChange(
        client: RuntimeClient,
        sel: Selector,
        before: VerifyState?,
        params: JsonObject,
    ): JsonElement {
        val budgetMs = (params.intOrNull("verifyTimeoutMs") ?: 2000).toLong()
        val deadline = System.currentTimeMillis() + budgetMs
        var after = captureState(client, sel)
        var changes = diff(before, after)
        while (changes.isEmpty() && System.currentTimeMillis() < deadline) {
            Thread.sleep(150)
            after = captureState(client, sel)
            changes = diff(before, after)
        }
        val selStr = sel.testId?.let { "#$it" }
            ?: sel.resourceId?.let { "@$it" }
            ?: sel.cssSelector?.let { "css=$it" }
            ?: sel.ref
            ?: "?"
        return buildJsonObject {
            put("selector", selStr)
            put("changed", changes.isNotEmpty())
            if (!after.found) put("note", "node not present after action")
            put("changes", buildJsonArray {
                changes.forEach { (field, ba) ->
                    add(buildJsonObject { put("field", field); put("before", ba.first); put("after", ba.second) })
                }
            })
        }
    }

    data class VerifyState(
        val found: Boolean,
        val text: String?,
        val label: String?,
        val enabled: Boolean,
        val visible: Boolean,
        val frame: String?,
        val custom: Map<String, String>,
    )

    private fun selectorParams(sel: Selector): JsonObject = buildJsonObject {
        sel.testId?.let { put("testId", it) }
        sel.resourceId?.let { put("resourceId", it) }
        sel.cssSelector?.let { put("css", it) }
        sel.ref?.let { put("ref", it) }
    }

    private fun diff(before: VerifyState?, after: VerifyState): Map<String, Pair<String?, String?>> {
        if (before == null) return emptyMap()
        val out = LinkedHashMap<String, Pair<String?, String?>>()
        if (before.found != after.found) out["present"] = before.found.toString() to after.found.toString()
        if (before.text != after.text) out["text"] = before.text to after.text
        if (before.label != after.label) out["label"] = before.label to after.label
        if (before.enabled != after.enabled) out["enabled"] = before.enabled.toString() to after.enabled.toString()
        if (before.visible != after.visible) out["visible"] = before.visible.toString() to after.visible.toString()
        if (before.frame != after.frame) out["frame"] = before.frame to after.frame
        (before.custom.keys + after.custom.keys).forEach { k ->
            val b = before.custom[k]
            val a = after.custom[k]
            if (b != a) out[k] = b to a
        }
        return out
    }
}

/**
 * Resolve a `--verify` token into the node selector to watch. Pure so it can be
 * unit-tested without a device.
 */
internal fun parseVerifyToken(
    token: String,
    actTestId: String?,
    actResourceId: String?,
    actCssSelector: String?,
    actRef: String?,
): Selector? = when {
    token == "false" -> null
    token == "true" -> {
        if (actTestId == null && actResourceId == null && actCssSelector == null && actRef == null) {
            throw CliError("--verify needs a node selector to watch: pass --verify <#testId|@resourceId|--css selector|ref>, or act by selector rather than --point")
        }
        Selector(
            testId = actTestId,
            resourceId = actResourceId,
            cssSelector = actCssSelector,
            ref = actRef,
        )
    }
    token.startsWith("#") -> Selector(testId = token.drop(1))
    token.startsWith("@") -> Selector(resourceId = token.drop(1))
    else -> Selector(ref = token)
}
