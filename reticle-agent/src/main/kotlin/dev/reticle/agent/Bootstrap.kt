package dev.reticle.agent

import android.app.Application
import android.content.Context
import android.util.Log

/**
 * Injection entrypoint for the **unlinked** path.
 *
 * The normal path is [ReticleInitProvider]: link the AAR and a ContentProvider
 * auto-starts the runtime. But for a debuggable app that does NOT link the agent,
 * the host CLI pushes this dex into the live process over JDWP and calls
 * [Bootstrap.start] — there's no ContentProvider, so we have to find the app
 * Context ourselves.
 *
 * Every Android app process has an `ActivityThread` singleton holding the
 * `Application`; `ActivityThread.currentApplication()` returns it. We reach it
 * reflectively to avoid a compile dependency on a hidden framework class.
 * Debugger-invoked calls (and debuggable apps generally) are exempt from
 * hidden-API enforcement, so the lookup resolves at runtime.
 *
 * Designed to be invoked with a single JDWP `InvokeMethod`: it takes no
 * arguments and returns the bound loopback port (or a negative error code), so
 * the injector gets an immediate, unambiguous result without a follow-up call.
 */
object Bootstrap {

    /** [start] succeeded but the server reported no bound port. */
    const val ERR_NO_PORT = -1

    /** Could not obtain the app [Context] (no ActivityThread/Application yet). */
    const val ERR_NO_CONTEXT = -2

    /** An exception escaped startup; see logcat tag `Reticle`. */
    const val ERR_THREW = -3

    /**
     * Start (or no-op re-confirm) the Reticle runtime in the current process and
     * return the bound loopback port, or one of the negative `ERR_*` codes.
     *
     * Idempotent: [ReticleRuntime.start] already guards against a double bind, so
     * a repeated injection just returns the live port.
     */
    @JvmStatic
    fun start(): Int {
        return try {
            val context = currentAppContext()
                ?: return ERR_NO_CONTEXT.also { Log.e(TAG, "Bootstrap: no app context") }
            ReticleRuntime.shared.start(context)
            val port = ReticleRuntime.shared.boundPort
            if (port > 0) {
                Log.i(TAG, "Bootstrap: injected runtime serving on port $port")
                port
            } else {
                Log.e(TAG, "Bootstrap: runtime started but no bound port")
                ERR_NO_PORT
            }
        } catch (t: Throwable) {
            Log.e(TAG, "Bootstrap: start failed", t)
            ERR_THREW
        }
    }

    /**
     * The current process's application [Context] via
     * `ActivityThread.currentApplication()`, or null if the framework hasn't
     * created the Application yet.
     */
    private fun currentAppContext(): Context? {
        return try {
            val activityThread = Class.forName("android.app.ActivityThread")
            val app = activityThread
                .getMethod("currentApplication")
                .invoke(null) as? Application
            app?.applicationContext
        } catch (t: Throwable) {
            Log.e(TAG, "Bootstrap: currentApplication() lookup failed", t)
            null
        }
    }

    private const val TAG = "Reticle"
}
