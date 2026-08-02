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
        is Real -> canonicalRealString(value)
    }

    companion object {
        /**
         * Canonical spelling of a `real`. `displayString()` feeds `verify
         * --custom` matching and trace diffs, so the same value captured on
         * either agent has to spell identically — and Swift's `String(Double)`
         * dresses its digits differently (`1e+17` / `inf` / `nan`). This
         * spelling is the canonical one because it is specified
         * (`java.lang.Double.toString`: plain decimal with at least one
         * fraction digit for `1e-3 <= |v| < 1e7`, `d.dddEn` otherwise,
         * `NaN`/`Infinity`/`-Infinity`) where Swift's is not; the Swift side
         * re-dresses its output to match in
         * `MetadataValue.canonicalRealString`. Keep the two in lockstep.
         */
        fun canonicalRealString(value: Double): String = value.toString()
    }
}
