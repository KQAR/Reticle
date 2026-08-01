package dev.reticle.core

/**
 * Clip for the render projections, counted in CODE POINTS.
 *
 * Kotlin's `take(n)` counts UTF-16 units, Swift's `prefix(n)` counts grapheme
 * clusters — the two ports agree on ASCII and quietly disagree on CJK and
 * emoji, and a UTF-16 clip can even land inside a surrogate pair, emitting an
 * unpaired surrogate that is not valid UTF-8 on the wire. The trace layer
 * already learned this (`clipIdentityText`); this is the same rule for every
 * `take(30/40)` the renderers do. A code point is exactly one Unicode scalar
 * on the Swift side, so both languages count the same thing.
 */
internal fun String.clipCodePoints(max: Int): String {
    if (codePointCount(0, length) <= max) return this
    return substring(0, offsetByCodePoints(0, max))
}
