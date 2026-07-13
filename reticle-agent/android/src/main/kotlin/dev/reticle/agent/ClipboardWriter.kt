package dev.reticle.agent

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Handler
import android.os.Looper

/**
 * Sets the device's primary clipboard from inside the app process.
 *
 * This is how Reticle stages text the host can't type directly: `adb shell input
 * text` is ASCII-only, and a host process can't reliably write the clipboard on
 * modern Android (no `cmd clipboard` on many builds, and API 29+ only lets the
 * *foreground app* write it). The agent runs inside that foreground app, so the
 * write succeeds; the CLI then dispatches KEYCODE_PASTE to commit it into the
 * focused field.
 *
 * `ClipboardManager.setPrimaryClip` must run on the main (UI) thread.
 */
class ClipboardWriter(private val context: Context) {

    private val handler = Handler(Looper.getMainLooper())

    /** Returns true if the clipboard was set. */
    fun set(text: String, label: String = "reticle"): Boolean = runOnMainSync(handler) {
        val cm = context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            ?: return@runOnMainSync false
        cm.setPrimaryClip(ClipData.newPlainText(label, text))
        true
    } ?: false
}
