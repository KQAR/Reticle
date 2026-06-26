package dev.reticle.cli.platform

/**
 * Gets the Reticle runtime running inside an app that does NOT link the agent,
 * with no root and no repackaging. Android does this over JDWP; other platforms
 * would have their own mechanism (or none, for non-debuggable builds).
 */
interface AppInjector {
    /** Inject and start the runtime in [packageName]. */
    fun inject(device: DeviceController, packageName: String): InjectResult

    /** The pid injected into, and the port Bootstrap.start() reported (a hint;
     *  real liveness is proven over HTTP by the caller). */
    data class InjectResult(val pid: Int, val reportedPort: Int)
}
