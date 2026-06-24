package dev.reticle.agent

import android.util.Log
import android.view.View

/**
 * Enumerates the attached window root views: we read the framework's
 * WindowManagerGlobal, which holds every attached decor/window root (the
 * activity window, dialogs, popup windows, toasts).
 *
 * There is no public API for this, so we reflect WindowManagerGlobal the same
 * way Layout Inspector and Ui Automator do. This is stable across modern API
 * levels; if it ever fails we degrade to an empty list rather than crash.
 */
object ReticleWindows {

    fun rootViews(): List<View> {
        return try {
            val wmgClass = Class.forName("android.view.WindowManagerGlobal")
            val getInstance = wmgClass.getMethod("getInstance")
            val instance = getInstance.invoke(null)

            // getRootViews(): View[] (added in API 19, stable since).
            try {
                val getRootViews = wmgClass.getMethod("getRootViews")
                @Suppress("UNCHECKED_CAST")
                val views = getRootViews.invoke(instance) as? Array<View>
                if (views != null) return views.toList()
            } catch (_: NoSuchMethodException) {
                // Fall through to the mViews field on older/odd ROMs.
            }

            val mViewsField = wmgClass.getDeclaredField("mViews").apply { isAccessible = true }
            when (val value = mViewsField.get(instance)) {
                is List<*> -> value.filterIsInstance<View>()
                is Array<*> -> value.filterIsInstance<View>()
                else -> emptyList()
            }
        } catch (t: Throwable) {
            Log.w("Reticle", "Failed to enumerate window roots", t)
            emptyList()
        }
    }
}
