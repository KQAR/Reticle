package dev.reticle.agent

import dev.reticle.core.Rect

/**
 * Reflective reader for Compose SemanticsNode. Kept isolated so the rest of the
 * agent never touches Compose types directly and the AAR has no hard Compose
 * dependency (compileOnly). Every accessor degrades to null on shape changes,
 * rather than inventing selectors from private internals.
 *
 * The relevant Compose APIs (stable in androidx.compose.ui 1.x):
 *   SemanticsNode.getConfig(): SemanticsConfiguration  (implements Iterable<Map.Entry>)
 *   SemanticsNode.getChildren(): List<SemanticsNode>
 *   SemanticsNode.getBoundsInWindow(): androidx.compose.ui.geometry.Rect
 *   SemanticsProperties.TestTag / Text / ContentDescription / Role keys
 */
object SemanticsReflect {

    fun children(node: Any): List<Any> {
        return try {
            val m = node.javaClass.methods.firstOrNull { it.name == "getChildren" } ?: return emptyList()
            (m.invoke(node) as? List<*>)?.filterNotNull() ?: emptyList()
        } catch (_: Throwable) {
            emptyList()
        }
    }

    fun testTag(node: Any): String? = configString(node, "TestTag")

    fun contentDescription(node: Any): String? {
        // ContentDescription is a List<String> in the config.
        val raw = configValue(node, "ContentDescription") ?: return null
        return when (raw) {
            is List<*> -> raw.filterIsInstance<String>().firstOrNull()
            is String -> raw
            else -> raw.toString()
        }
    }

    fun text(node: Any): String? {
        val raw = configValue(node, "Text") ?: return null
        return when (raw) {
            is List<*> -> raw.joinToString(" ") { it.toString() }
            else -> raw.toString()
        }
    }

    fun role(node: Any): String? = configValue(node, "Role")?.toString()

    fun hasClickAction(node: Any): Boolean = configValue(node, "OnClick") != null

    /**
     * Bounds of the node relative to its host window (Compose's
     * getBoundsInWindow). Callers convert to screen coordinates by adding the
     * host View's window origin, so Compose frames sit in the same coordinate
     * space as View frames (which use getLocationOnScreen).
     */
    fun boundsInWindow(node: Any): Rect? {
        return try {
            val m = node.javaClass.methods.firstOrNull { it.name == "getBoundsInWindow" } ?: return null
            val rect = m.invoke(node) ?: return null
            val left = (rect.javaClass.methods.first { it.name == "getLeft" }.invoke(rect) as Float).toDouble()
            val top = (rect.javaClass.methods.first { it.name == "getTop" }.invoke(rect) as Float).toDouble()
            val right = (rect.javaClass.methods.first { it.name == "getRight" }.invoke(rect) as Float).toDouble()
            val bottom = (rect.javaClass.methods.first { it.name == "getBottom" }.invoke(rect) as Float).toDouble()
            Rect(x = left, y = top, width = right - left, height = bottom - top)
        } catch (_: Throwable) {
            null
        }
    }

    // --- config access ----------------------------------------------------

    private fun configString(node: Any, keyName: String): String? =
        configValue(node, keyName)?.toString()

    /**
     * Reads a SemanticsProperties key value from the node's config. The config
     * is iterable over Map.Entry<SemanticsPropertyKey, Object>; each key has a
     * getName() we match against [keyName].
     */
    private fun configValue(node: Any, keyName: String): Any? {
        return try {
            val getConfig = node.javaClass.methods.firstOrNull { it.name == "getConfig" } ?: return null
            val config = getConfig.invoke(node) as? Iterable<*> ?: return null
            for (entry in config) {
                entry ?: continue
                val key = entry.javaClass.methods.firstOrNull { it.name == "getKey" }?.invoke(entry) ?: continue
                val name = key.javaClass.methods.firstOrNull { it.name == "getName" }?.invoke(key)?.toString()
                if (name == keyName) {
                    return entry.javaClass.methods.firstOrNull { it.name == "getValue" }?.invoke(entry)
                }
            }
            null
        } catch (_: Throwable) {
            null
        }
    }
}
