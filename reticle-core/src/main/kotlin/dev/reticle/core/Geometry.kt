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
    /**
     * System font-scale multiplier at capture time (Android
     * `Configuration.fontScale`; on iOS the Dynamic Type scale of a body font),
     * or null when the platform did not probe it.
     *
     * Without it a raw text size cannot be split into the two questions a
     * consumer actually asks: *is this the size the design specifies* (compare in
     * dp, which divides out [density] only) and *is the user scaling text right
     * now* (compare in sp, which divides out both). One number cannot answer
     * both, and guessing 1.0 turns "the user enlarged text" into "the app got the
     * font size wrong".
     */
    val fontScale: Double? = null,
    /** "light" | "dark" — Ui mode night flag. */
    val interfaceStyle: String? = null,
    /**
     * System keyboard (IME) state at capture time, or null when the platform
     * did not probe it. The IME is a separate window owned by another process,
     * so it never appears in the node tree — this field is the only place a
     * snapshot records that part of the screen is covered by the keyboard.
     */
    val keyboard: KeyboardInfo? = null,
    /**
     * Does this app's top window still hold input focus? Null when the platform
     * did not probe it.
     *
     * The honest answer to the one on-screen thing an in-process agent cannot
     * see. A system permission prompt, a biometric sheet, an autofill dialog —
     * all belong to another process, so they appear in no window of this app and
     * in no node of this tree. A capture taken while one is up looks like an
     * ordinary screen with every control still "tappable", yet input goes
     * elsewhere. This flag does not reveal what is on top; it reports the fact
     * that something is, which is enough for an agent to stop instead of tapping
     * into a void.
     */
    val windowFocused: Boolean? = null,
)

@Serializable
data class KeyboardInfo(
    val visible: Boolean,
    /** Screen-coordinate rect the IME occupies; null when hidden or unknown. */
    val frame: Rect? = null,
)
