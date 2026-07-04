package dev.reticle.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Scalar metadata value: values are intentionally scalar (string / bool / int /
 * double) so app-authored metadata stays a flat, predictable shape across the
 * wire.
 *
 * The `_type` discriminator is a short, language-neutral tag (`text`/`bool`/
 * `int`/`real`) rather than the Kotlin FQ class name, so it stays cheap on the
 * wire (repeated per custom property) and does not couple the format to Kotlin
 * package names. Keep these `@SerialName` values in lockstep with the enum in
 * `reticle-protocol/schema/snapshot.schema.json`.
 */
@Serializable
sealed class MetadataValue {
    @Serializable
    @SerialName("text")
    data class Text(val value: String) : MetadataValue()

    @Serializable
    @SerialName("bool")
    data class Bool(val value: Boolean) : MetadataValue()

    @Serializable
    @SerialName("int")
    data class Integer(val value: Long) : MetadataValue()

    @Serializable
    @SerialName("real")
    data class Real(val value: Double) : MetadataValue()

    fun displayString(): String = when (this) {
        is Text -> value
        is Bool -> value.toString()
        is Integer -> value.toString()
        is Real -> value.toString()
    }
}
