package dev.reticle.cli.platform

import dev.reticle.cli.CliError
import dev.reticle.cli.platform.android.AndroidPlatform

/**
 * Resolves the active [Platform]. Android is the only implementation today and
 * the default; `--target` / RETICLE_TARGET are accepted now so the selection
 * point exists before a second platform lands (no stubs for absent platforms —
 * an unknown target fails loudly).
 */
object Platforms {
    const val DEFAULT = "android"

    fun current(target: String? = null): Platform {
        val id = target ?: System.getenv("RETICLE_TARGET") ?: DEFAULT
        return when (id) {
            "android" -> AndroidPlatform
            else -> throw CliError(
                "unsupported --target '$id'. Only 'android' is implemented today."
            )
        }
    }
}
