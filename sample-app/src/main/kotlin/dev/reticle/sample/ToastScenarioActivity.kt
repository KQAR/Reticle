package dev.reticle.sample

import android.content.Context
import android.graphics.PixelFormat
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/**
 * The three things people call "a toast", which are three different observation
 * problems. Measured on an API 36 emulator, one channel per column:
 *
 * |                          | view tree | agent screenshot | Toast Queue        |
 * |--------------------------|-----------|------------------|--------------------|
 * | `Toast.makeText`         | absent    | absent           | **text verbatim**  |
 * | `Toast.setView`          | **present** | present        | record, no text    |
 * | app overlay (WindowManager) | **present** | present     | absent (not a Toast) |
 *
 * Only the first row is a blind spot, and it is the common one: an app rejecting
 * a submit says so with `Toast.makeText`. On Android 11+ that toast is drawn by
 * the SYSTEM in a window of its own, so it is in no snapshot of this app and in
 * no in-process screenshot — the before/after pair is byte-identical and the step
 * reads `0 change(s)`, which is the documented signal for a gesture that hit
 * nothing. Two findings needing opposite responses, one reading. That is the
 * report this scenario exists for.
 *
 * The other two rows are here to keep the fix honest in the other direction: they
 * are ALREADY visible as their own window node carrying the text, so a reader must
 * not conclude that "toast" means "unreachable". A custom-view toast's queue
 * record carries a callback rather than a string, so the queue and the tree each
 * hold half the answer and neither is redundant.
 */
class ToastScenarioActivity : AppCompatActivity() {

    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        status = TextView(this).apply {
            text = "Idle"
            textSize = 18f
            tag = "toast.status"
        }

        setContentView(
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.TOP
                setPadding(48, 48, 48, 48)
                addView(status)
                addView(
                    row("Text toast (system-drawn)", "toast.text") {
                        Toast.makeText(
                            this@ToastScenarioActivity, TEXT_MESSAGE, Toast.LENGTH_LONG,
                        ).show()
                    }
                )
                addView(
                    row("Custom-view toast (app-drawn)", "toast.customView") { showCustomViewToast() }
                )
                addView(
                    row("WindowManager overlay", "toast.overlay") { showOverlay() }
                )
            }
        )
    }

    /**
     * The submit-was-rejected shape. Deliberately leaves the screen otherwise
     * untouched — `status` is NOT updated — so the before/after pair really is
     * identical and the scenario reproduces `0 change(s)` rather than papering
     * over it with a state change no real rejection would make.
     */
    private fun row(label: String, tag: String, onTap: () -> Unit): Button =
        Button(this).apply {
            text = label
            this.tag = tag
            setOnClickListener {
                Reticle.log("toast_raised", mapOf("kind" to tag))
                onTap()
            }
        }

    /**
     * `Toast.setView` — deprecated in API 30 and blocked from the background, but
     * alive and extremely common from the foreground, which is where a form submit
     * runs. The view belongs to THIS process, so it lands in the tree.
     */
    @Suppress("DEPRECATION")
    private fun showCustomViewToast() {
        val body = TextView(this).apply {
            text = CUSTOM_MESSAGE
            tag = "toast.customView.body"
            setPadding(48, 32, 48, 32)
            setBackgroundColor(0xFF333333.toInt())
            setTextColor(0xFFFFFFFF.toInt())
        }
        Toast(this).apply {
            duration = Toast.LENGTH_LONG
            view = body
            setGravity(Gravity.BOTTOM, 0, 200)
        }.show()
    }

    /**
     * Not a `Toast` at all: a view the app adds to its own window stack and takes
     * away on a timer. The house style of a great many in-app "toast" libraries,
     * and the reason the Toast Queue cannot be the only channel — this one never
     * enters it.
     */
    private fun showOverlay() {
        val manager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val body = TextView(this).apply {
            text = OVERLAY_MESSAGE
            tag = "toast.overlay.body"
            setPadding(48, 32, 48, 32)
            setBackgroundColor(0xFF224466.toInt())
            setTextColor(0xFFFFFFFF.toInt())
        }
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_APPLICATION_PANEL,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
            PixelFormat.TRANSLUCENT,
        ).apply {
            token = window.decorView.windowToken
            gravity = Gravity.BOTTOM
            y = 400
        }
        manager.addView(body, params)
        body.postDelayed({ runCatching { manager.removeView(body) } }, OVERLAY_MS)
    }

    private companion object {
        const val TEXT_MESSAGE = "Amount exceeds your daily limit"
        const val CUSTOM_MESSAGE = "Custom view: amount exceeds your limit"
        const val OVERLAY_MESSAGE = "Overlay: amount exceeds your limit"

        /** Long enough to be sampled, short enough not to bleed into the next step. */
        const val OVERLAY_MS = 3_500L
    }
}
