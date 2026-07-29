package dev.reticle.agent

import dev.reticle.core.MetadataValue

/**
 * Registry of app-authored probe nodes that appear as synthetic children of the
 * application node — a way for app code to expose a stable, addressable point of
 * interest even when no concrete view is convenient.
 */
object ReticleProbeRegistry {
    private val probes = LinkedHashMap<String, Map<String, MetadataValue>>()

    fun register(testId: String, metadata: Map<String, MetadataValue>) {
        synchronized(probes) { probes[testId] = metadata }
    }

    fun all(): Map<String, Map<String, MetadataValue>> =
        synchronized(probes) { LinkedHashMap(probes) }

    /**
     * Forget every registered probe. Process-global state that nothing removed
     * from was a leak by construction — an app that publishes a screen's probes
     * on entry had no way to retract them on exit, so a stale testId stayed
     * addressable on every later screen. The unit tests need it for the same
     * reason: a singleton that survives between them is shared state.
     */
    fun clear() {
        synchronized(probes) { probes.clear() }
    }
}
