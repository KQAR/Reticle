package dev.reticle.cli.platform

/**
 * Gets the Reticle runtime running inside an app that does NOT link the agent,
 * with no root and no repackaging — over JDWP, for a debuggable APK. An internal
 * seam of the Android helper: this mechanism is the whole reason a Kotlin helper
 * exists at all (see the "Swift host + per-platform helpers" decision), so it is
 * Android-only by construction, not pending a second implementation.
 */
interface AppInjector {
    /**
     * Inject and start the runtime in [packageName].
     *
     * @param restartUnderDebugger mark the app as being debugged first, which makes
     *   AMS relax the input-dispatch ANR verdict during the JDWP suspension. Costly
     *   and therefore opt-in: setting the debug app FORCE-STOPS the target, so the
     *   app is relaunched and the screen it was on is lost.
     */
    fun inject(
        device: DeviceController,
        packageName: String,
        restartUnderDebugger: Boolean = false,
    ): InjectResult

    /** The pid injected into, and the port Bootstrap.start() reported (a hint;
     *  real liveness is proven over HTTP by the caller). */
    data class InjectResult(val pid: Int, val reportedPort: Int)
}
