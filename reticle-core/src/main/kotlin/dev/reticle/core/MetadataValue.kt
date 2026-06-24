package dev.reticle.core

import kotlinx.serialization.Serializable

/**
 * Scalar metadata value: values are intentionally scalar (string / bool / int /
 * double) so app-authored metadata stays a flat, predictable shape across the
 * wire.
 */
@Serializable
sealed class MetadataValue {
    @Serializable
    data class Text(val value: String) : MetadataValue()

    @Serializable
    data class Bool(val value: Boolean) : MetadataValue()

    @Serializable
    data class Integer(val value: Long) : MetadataValue()

    @Serializable
    data class Real(val value: Double) : MetadataValue()

    fun displayString(): String = when (this) {
        is Text -> value
        is Bool -> value.toString()
        is Integer -> value.toString()
        is Real -> value.toString()
    }
}
