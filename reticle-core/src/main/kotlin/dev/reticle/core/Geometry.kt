package dev.reticle.core

import kotlinx.serialization.Serializable

/** Geometry primitives: size, point, and rect on the wire. */
@Serializable
data class Size(val width: Double, val height: Double)

@Serializable
data class Point(val x: Double, val y: Double)

@Serializable
data class Rect(
    val x: Double,
    val y: Double,
    val width: Double,
    val height: Double,
) {
    val centerX: Double get() = x + width / 2.0
    val centerY: Double get() = y + height / 2.0

    fun contains(px: Double, py: Double): Boolean =
        px >= x && px <= x + width && py >= y && py <= y + height
}

@Serializable
data class ScreenInfo(
    val size: Size,
    /** Display density (dpi / 160). Android analogue of UIScreen.scale. */
    val density: Double,
    /** "light" | "dark" — Ui mode night flag. */
    val interfaceStyle: String? = null,
)
