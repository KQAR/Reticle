package dev.reticle.agent

import dev.reticle.core.MetadataValue

/**
 * Public app-facing entry point: the app-authored log / view-metadata bridge
 * and the linked agent API.
 *
 * A linked app can call these directly. Everything is optional: the agent
 * already captures the tree and serves it without any app code. These calls
 * just enrich the evidence with app-authored logs and stable metadata.
 *
 * Example:
 *   Reticle.log("checkout_visible", mapOf("cartId" to "cart-123", "items" to 3))
 *   Reticle.attachMetadata("checkout.payButton", mapOf("variant" to "primary"))
 */
object Reticle {

    fun log(message: String, metadata: Map<String, Any?> = emptyMap(), level: String = "info") {
        ReticleRuntime.shared.log(level, message, metadata.toScalarMap())
    }

    /** Attach scalar metadata addressed by stable testId (Compose testTag). */
    fun attachMetadata(testId: String, metadata: Map<String, Any?>) {
        ReticleRuntime.shared.attachMetadata(testId, metadata.toScalarMap())
    }

    private fun Map<String, Any?>.toScalarMap(): Map<String, MetadataValue> {
        val out = LinkedHashMap<String, MetadataValue>()
        for ((key, value) in this) {
            val scalar = when (value) {
                is String -> MetadataValue.Text(value)
                is Boolean -> MetadataValue.Bool(value)
                is Int -> MetadataValue.Integer(value.toLong())
                is Long -> MetadataValue.Integer(value)
                is Float -> MetadataValue.Real(value.toDouble())
                is Double -> MetadataValue.Real(value)
                null -> continue
                else -> MetadataValue.Text(value.toString())
            }
            out[key] = scalar
        }
        return out
    }
}
