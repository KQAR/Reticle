package dev.reticle.agent

/**
 * A stand-in for Compose's `SemanticsNode`, spelled the way `SemanticsReflect`
 * reads it.
 *
 * `SemanticsReflect` touches no Compose type by name — it is duck-typed all the
 * way down (`getConfig()` iterable of `Map.Entry`, each key answering `getName()`,
 * `getChildren()`, `getBoundsInWindow()`), which is exactly what keeps the AAR's
 * Compose dependency `compileOnly`. So a stand-in exercises the REAL code path
 * rather than a mock of it, and the property NAMES it matches on — `TestTag`,
 * `EditableText`, `ToggleableState`, `VerticalScrollAxisRange` — are the contract
 * this pins.
 *
 * Public top-level classes for the reason `LottieFakeModel` is: the reader calls
 * `getMethod(...).invoke(...)` with no `setAccessible`, so a member of a private
 * nested class would throw, be swallowed, and the suite would pass against
 * nothing. What this cannot prove is that Compose still uses these names — only
 * `scenario.compose` in the device e2e can — but it is the half that regresses
 * silently when this file's own logic is edited.
 */
class FakeSemanticsKey(private val name: String) {
    fun getName(): String = name
}

/** Compose's config iterates as `Map.Entry<SemanticsPropertyKey, Any>`. */
class FakeSemanticsConfig(
    private val entries: List<Map.Entry<FakeSemanticsKey, Any>>,
) : Iterable<Map.Entry<FakeSemanticsKey, Any>> {
    override fun iterator(): Iterator<Map.Entry<FakeSemanticsKey, Any>> = entries.iterator()
}

/** `androidx.compose.ui.geometry.Rect` — four Floats behind four getters. */
class FakeComposeRect(
    private val left: Float,
    private val top: Float,
    private val right: Float,
    private val bottom: Float,
) {
    fun getLeft(): Float = left
    fun getTop(): Float = top
    fun getRight(): Float = right
    fun getBottom(): Float = bottom
}

/**
 * `ScrollAxisRange` exposes `value`/`maxValue` as `() -> Float` LAMBDAS, not
 * plain floats — the indirection is part of what the reader has to get right.
 */
class FakeScrollAxisRange(
    private val value: Float,
    private val maxValue: Float,
    private val reverseScrolling: Boolean = false,
) {
    fun getValue(): () -> Float = { value }
    fun getMaxValue(): () -> Float = { maxValue }
    fun getReverseScrolling(): Boolean = reverseScrolling
}

class FakeSemanticsNode(
    properties: Map<String, Any>,
    private val children: List<FakeSemanticsNode> = emptyList(),
    private val bounds: FakeComposeRect? = null,
) {
    private val config = FakeSemanticsConfig(
        properties.entries.map { java.util.AbstractMap.SimpleEntry(FakeSemanticsKey(it.key), it.value) }
    )

    fun getConfig(): FakeSemanticsConfig = config
    fun getChildren(): List<FakeSemanticsNode> = children
    fun getBoundsInWindow(): FakeComposeRect? = bounds
}
