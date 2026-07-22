package dev.reticle.agent

import android.graphics.drawable.ColorDrawable
import android.view.View

/**
 * Small reflection/inspection helpers for reading stable selectors and scalar
 * style off a View, turning views into scalar custom properties.
 */
object ReticleReflect {

    /** Android resource-id entry name, e.g. R.id.checkout_pay_button -> "checkout_pay_button". */
    fun resourceEntryName(view: View): String? {
        val id = view.id
        if (id == View.NO_ID) return null
        return try {
            val res = view.resources ?: return null
            if (id <= 0) return null
            res.getResourceEntryName(id)
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Compose testTag set on a View, or a View tag used as a stable id.
     * Compose's AndroidComposeView does not put testTags on Views; those are
     * read by ComposeSemanticsBridge. This covers the classic-View testTag
     * convention (view.tag as a String id) used by many apps.
     */
    fun testTag(view: View): String? {
        val tag = view.tag
        if (tag is String && tag.isNotBlank()) return tag
        return null
    }

    /**
     * React Native's `nativeID` prop. RN stores it as a *keyed* tag —
     * `view.setTag(R.id.view_tag_native_id, value)` — so it is invisible to the
     * keyless [testTag] read (RN's `testID` also writes the keyless tag; this
     * covers the nativeID-only case). The R.id constant lives in RN's resources,
     * so resolve it by name at runtime; 0 means RN isn't in this app.
     */
    fun nativeId(view: View): String? {
        return try {
            val context = view.context ?: return null
            val resId = nativeIdResource.getOrPut(context.packageName) {
                context.resources.getIdentifier("view_tag_native_id", "id", context.packageName)
            }
            if (resId == 0) return null
            val tag = view.getTag(resId)
            if (tag is String && tag.isNotBlank()) tag else null
        } catch (_: Throwable) {
            null
        }
    }

    /** package name -> resolved view_tag_native_id resource (0 = absent). */
    private val nativeIdResource = HashMap<String, Int>()

    fun backgroundColorHex(view: View): String? {
        val bg = view.background
        if (bg is ColorDrawable) return colorHex(bg.color)
        return null
    }

    fun colorHex(color: Int): String =
        String.format("#%08X", color)
}
