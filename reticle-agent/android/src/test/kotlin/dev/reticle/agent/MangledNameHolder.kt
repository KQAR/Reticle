package dev.reticle.agent

/**
 * Stands in for a Compose value-class getter.
 *
 * Kotlin mangles the JVM name of a function whose signature involves an inline
 * value class (`Dp`, `TextUnit`, `Color`), so Compose's `getFontSize` really is on
 * the class as `getFontSize-XSAIIZE`. `ReticleReflect.invokeNoArgByPrefix` reads
 * those by prefix rather than hard-coding a hash that differs between Compose
 * builds — and that is the whole of `ComposeTextStyle`'s access to text style.
 *
 * A backticked declaration reproduces the mangled shape exactly, without pulling
 * Compose into the agent's test classpath. Public and top-level because the
 * reflection helper calls `getMethod(...).invoke(...)` with no `setAccessible`.
 */
class MangledNameHolder {
    @Suppress("FunctionName")
    fun `getFontSize-XSAIIZE`(): Long = 14L

    fun getFontFamily(): String = "Inter"

    /**
     * A trap for the prefix match: `getFontSizeScale` starts with `getFontSize`
     * as a plain string but is a DIFFERENT property. The helper matches
     * `prefix` exactly or `prefix-`, so this must not be picked up.
     */
    fun getFontSizeScale(): Double = 2.0
}
