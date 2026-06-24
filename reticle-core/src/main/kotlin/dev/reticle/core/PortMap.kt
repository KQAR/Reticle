package dev.reticle.core

/**
 * Deterministic loopback-port assignment, shared verbatim by the in-app agent
 * and the host CLI.
 *
 * Android shares one network stack across all apps, so `127.0.0.1:<port>` is a
 * device-global resource: if every linked app bound the same fixed port, only
 * the first to start would win and the rest would silently fail to bind — and a
 * host `adb forward` to that port could land on the *wrong* app's server. (That
 * exact collision is what makes a forward connect yet never return the data you
 * expect.)
 *
 * The fix is to derive each app's port from its applicationId with a stable hash
 * that both sides compute identically. The agent binds `derivePort(packageName)`
 * and the CLI forwards to the same value computed from `--package` — no
 * discovery round-trip needed. Two different apps collide only on a ~1/[RANGE]
 * hash clash, which the CLI's runtime identity check still catches.
 *
 * The hash is FNV-1a (not [String.hashCode]) so the mapping is explicit, stable
 * across JVM/Android and future runtime changes, and easy to reproduce in any
 * language a future port of the agent might use.
 */
object PortMap {

    /** Base of the assigned range; also the historical default port. */
    const val BASE_PORT = 8765

    /** Number of distinct ports in the range [BASE_PORT, BASE_PORT + RANGE). */
    const val RANGE = 1000

    /**
     * The loopback port the agent for [packageName] binds and the CLI forwards
     * to. Falls back to [BASE_PORT] for a blank package name.
     */
    fun derivePort(packageName: String): Int {
        if (packageName.isBlank()) return BASE_PORT
        val h = fnv1a32(packageName)
        // Unsigned modulo into the range; keep ports well clear of privileged
        // and ephemeral-allocation ranges.
        val offset = (h.toLong() and 0xFFFFFFFFL).rem(RANGE.toLong()).toInt()
        return BASE_PORT + offset
    }

    /** 32-bit FNV-1a over the UTF-8 bytes of [s]. */
    private fun fnv1a32(s: String): Int {
        var hash = -0x7ee3623b // 0x811C9DC5, the FNV offset basis
        for (b in s.toByteArray(Charsets.UTF_8)) {
            hash = hash xor (b.toInt() and 0xFF)
            hash *= 0x01000193 // FNV prime
        }
        return hash
    }
}
