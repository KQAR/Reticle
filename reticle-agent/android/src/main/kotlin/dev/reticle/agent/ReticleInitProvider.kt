package dev.reticle.agent

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.util.Log

/**
 * Auto-start hook. Android has no per-process constructor we can rely on for
 * arbitrary apps, so the closest no-code-change equivalent is a ContentProvider,
 * which the framework instantiates during process startup before
 * Application.onCreate hands control to UI.
 *
 * Just by depending on the AAR, a *debuggable* host app gets the Reticle server
 * started. The loopback server has no authentication, so any local app on the
 * device could otherwise read the UI tree, mutate views, and write the
 * clipboard. To avoid exposing that surface in shipped apps, auto-start is
 * gated on the app being debuggable (the normal Reticle dev/QA target, which is
 * already open to `run-as`/JDWP) or an explicit opt-in — `<meta-data
 * android:name="dev.reticle.agent.enabled" android:value="true"/>`. The JDWP
 * injection path ([Bootstrap]) calls the runtime directly and is unaffected,
 * since injecting is itself an explicit action. Opt out entirely with the
 * RETICLE_DISABLED env.
 */
class ReticleInitProvider : ContentProvider() {

    override fun onCreate(): Boolean {
        val context = context?.applicationContext ?: return false
        if (!autoStartAllowed(context)) {
            Log.i(
                TAG,
                "Reticle auto-start skipped: app is not debuggable and " +
                    "dev.reticle.agent.enabled meta-data is not set",
            )
            return true
        }
        try {
            ReticleRuntime.shared.start(context)
        } catch (t: Throwable) {
            Log.e(TAG, "Reticle failed to start", t)
        }
        return true
    }

    /**
     * Auto-start only in a debuggable build, or when the host app explicitly
     * opts in via manifest meta-data. This keeps the unauthenticated loopback
     * server out of shipped, non-debuggable apps that merely link the AAR.
     */
    private fun autoStartAllowed(context: Context): Boolean {
        val debuggable = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (debuggable) return true
        return runCatching {
            context.packageManager
                .getApplicationInfo(context.packageName, PackageManager.GET_META_DATA)
                .metaData
                ?.getBoolean("dev.reticle.agent.enabled", false)
        }.getOrNull() == true
    }

    // --- Unused ContentProvider surface ----------------------------------

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0

    private companion object {
        const val TAG = "Reticle"
    }
}
