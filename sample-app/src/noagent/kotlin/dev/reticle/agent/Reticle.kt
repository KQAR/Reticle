package dev.reticle.agent

/**
 * No-op stand-in for the real `Reticle` facade, present ONLY in the `noagent`
 * sample flavor. The `noagent` flavor does not depend on :reticle-agent:android, so this
 * lets MainActivity compile and run with zero Reticle runtime classes in the APK.
 *
 * This is the honest test target for `reticle app inject`: an app that calls a
 * Reticle-shaped API but carries no server, no ReticleRuntime, and no
 * ContentProvider — exactly the situation an unlinked third-party app is in. When
 * the host injects the payload dex, the real dev.reticle.agent.* classes load in a
 * separate DexClassLoader, so they never clash with this stub.
 */
object Reticle {
    fun log(message: String, metadata: Map<String, Any?> = emptyMap(), level: String = "info") {
        // Intentionally empty: no runtime to record into.
    }

    fun attachMetadata(testId: String, metadata: Map<String, Any?>) {
        // Intentionally empty.
    }
}
