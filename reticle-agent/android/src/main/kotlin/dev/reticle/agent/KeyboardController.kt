package dev.reticle.agent

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.inputmethod.InputMethodManager
import dev.reticle.core.KeyboardHideResult
import dev.reticle.core.KeyboardInfo

/**
 * Reads and dismisses the system keyboard from inside the app process.
 *
 * Hiding through InputMethodManager is deterministic in a way no host-side
 * input is: `keyevent KEYCODE_BACK` navigates back when the keyboard is
 * already gone, and `KEYCODE_ESCAPE` is OEM-dependent. In-process we ask the
 * IMM directly against every attached window token and then re-probe, so the
 * caller gets the settled state back instead of guessing.
 */
class KeyboardController(private val context: Context) {

    private val handler = Handler(Looper.getMainLooper())

    /** Current IME state, or null when no window is attached to read it from. */
    fun status(): KeyboardInfo? = runOnMainSync(handler) { KeyboardProbe.probe(context) }

    /**
     * Ask the IMM to hide the keyboard for every attached window, wait for the
     * hide animation to settle, and answer with before/after state. Null when
     * the state can't be read at all (no attached windows).
     */
    fun hide(): KeyboardHideResult? {
        val before = status() ?: return null
        if (before.visible) {
            runOnMainSync(handler) {
                val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
                for (root in ReticleWindows.rootViews()) {
                    root.windowToken?.let { imm.hideSoftInputFromWindow(it, 0) }
                }
            }
            // Give the IME its hide animation before re-probing; without this
            // the answer races the animation and reports "still visible".
            Thread.sleep(HIDE_SETTLE_MS)
        }
        val after = status() ?: before
        return KeyboardHideResult(wasVisible = before.visible, keyboard = after)
    }

    private companion object {
        const val HIDE_SETTLE_MS = 300L
    }
}
