package dev.reticle.agent

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.inputmethod.EditorInfo
import android.widget.TextView
import dev.reticle.core.EditorActionResult

/**
 * Performs the focused field's IME editor action (the keyboard's Done / Next /
 * Go / Search / Send key) from inside the app process.
 *
 * TextView.onEditorAction() invokes the app's OnEditorActionListener — the
 * exact hook React Native's onSubmitEditing and classic form handlers listen
 * on — where a host-side KEYCODE_ENTER inserts a newline into multiline
 * fields and is dropped outright by some IMEs.
 */
internal class EditorActionController(private val context: Context) {

    private val handler = Handler(Looper.getMainLooper())

    /**
     * Perform the focused TextView's IME action and answer with the settled
     * keyboard state. `performed = false` when no attached window has a
     * focused text field (or the main thread stalled).
     */
    fun perform(): EditorActionResult {
        val action = runOnMainSync(handler) {
            val field = focusedTextView() ?: return@runOnMainSync null
            val action = imeAction(field)
            field.onEditorAction(action)
            action
        }
        if (action == null) {
            return EditorActionResult(performed = false, message = "no focused text field")
        }
        // A real IME dismisses itself after a terminal action (Done/Go/Search/
        // Send); TextView.onEditorAction() bypasses the IME, so reproduce that
        // here. Next/Previous keep the keyboard up, like the physical key.
        val keyboard = if (action in TERMINAL_ACTIONS) {
            KeyboardController(context).hide()?.keyboard
        } else {
            Thread.sleep(SETTLE_MS)
            runOnMainSync(handler) { KeyboardProbe.probe(context) }
        }
        return EditorActionResult(performed = true, action = actionName(action), keyboard = keyboard)
    }

    /**
     * The focused text field across every attached window — dialogs and popup
     * windows hold focus while the activity's base window does not, so walk
     * them all like KeyboardProbe does.
     */
    private fun focusedTextView(): TextView? =
        ReticleWindows.rootViews().asSequence()
            .mapNotNull { it.findFocus() as? TextView }
            .firstOrNull()

    /**
     * The action the keyboard's action key would send for this field. Fields
     * that never declared one (unspecified/none) still submit on most IMEs;
     * treat them as Done so `--submit` works on undecorated inputs too.
     */
    private fun imeAction(field: TextView): Int {
        val action = field.imeOptions and EditorInfo.IME_MASK_ACTION
        return when (action) {
            EditorInfo.IME_ACTION_UNSPECIFIED, EditorInfo.IME_ACTION_NONE -> EditorInfo.IME_ACTION_DONE
            else -> action
        }
    }

    private fun actionName(action: Int): String = when (action) {
        EditorInfo.IME_ACTION_DONE -> "done"
        EditorInfo.IME_ACTION_GO -> "go"
        EditorInfo.IME_ACTION_NEXT -> "next"
        EditorInfo.IME_ACTION_PREVIOUS -> "previous"
        EditorInfo.IME_ACTION_SEARCH -> "search"
        EditorInfo.IME_ACTION_SEND -> "send"
        else -> "action-$action"
    }

    private companion object {
        /** Same settle the keyboard-hide path uses for the IME animation. */
        const val SETTLE_MS = 300L

        /** Actions after which a real IME dismisses itself. */
        val TERMINAL_ACTIONS = setOf(
            EditorInfo.IME_ACTION_DONE,
            EditorInfo.IME_ACTION_GO,
            EditorInfo.IME_ACTION_SEARCH,
            EditorInfo.IME_ACTION_SEND,
        )
    }
}
