package dev.reticle.cli.platform

/**
 * Gets the Reticle runtime running inside an app that does NOT link the agent,
 * with no root and no repackaging — over JDWP, for a debuggable APK. An internal
 * seam of the Android helper: this mechanism is the whole reason a Kotlin helper
 * exists at all (see the "Swift host + per-platform helpers" decision), so it is
 * Android-only by construction, not pending a second implementation.
 */
interface AppInjector {
    /** Inject and start the runtime in [packageName]. */
    fun inject(device: DeviceController, packageName: String): InjectResult

    /** The pid injected into, and the port Bootstrap.start() reported (a hint;
     *  real liveness is proven over HTTP by the caller). */
    data class InjectResult(val pid: Int, val reportedPort: Int)
}
