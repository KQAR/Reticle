package dev.reticle.agent

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.util.Log

/**
 * Auto-start hook. Android has no per-process constructor we can rely on for
 * arbitrary apps, so the closest no-code-change equivalent is a ContentProvider,
 * which the framework instantiates during process startup before
 * Application.onCreate hands control to UI.
 *
 * Just by depending on the AAR, a host app gets the Reticle server started.
 * Opt out with the manifest meta-data flag or the RETICLE_DISABLED env.
 */
class ReticleInitProvider : ContentProvider() {

    override fun onCreate(): Boolean {
        val context = context?.applicationContext ?: return false
        try {
            ReticleRuntime.shared.start(context)
        } catch (t: Throwable) {
            Log.e(TAG, "Reticle failed to start", t)
        }
        return true
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
