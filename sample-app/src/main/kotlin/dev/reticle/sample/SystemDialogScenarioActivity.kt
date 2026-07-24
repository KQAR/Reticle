package dev.reticle.sample

import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/**
 * A native alert dialog raised over the activity. The dialog is a *separate*
 * window (its own `ViewRootImpl`, added to `WindowManagerGlobal`), so this is
 * the scenario that exercises Reticle's multi-window walk: the capture must
 * surface the dialog's own content (title / message / buttons) AND mark the
 * background button behind it as occluded by the dialog window.
 *
 * A true system-owned dialog (a runtime-permission prompt) lives in another
 * process and is out of reach for an in-process agent — this is the app-owned
 * `AlertDialog`, which is exactly what Reticle can and should recognize.
 */
class SystemDialogScenarioActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 48)
        }

        val status = TextView(this).apply {
            text = "No choice yet"
            textSize = 20f
            tag = "dialog.status"
        }

        val trigger = Button(this).apply {
            text = "Delete account"
            tag = "dialog.trigger"
            setOnClickListener {
                Reticle.log("dialog_opened", mapOf("kind" to "alert"))
                showConfirmDialog(status)
            }
        }

        root.addView(status)
        root.addView(trigger)
        setContentView(root)

        Reticle.log("dialog_visible", mapOf("screen" to "systemDialog"))
    }

    private fun showConfirmDialog(status: TextView) {
        AlertDialog.Builder(this)
            .setTitle("Delete account?")
            .setMessage("This action cannot be undone.")
            .setPositiveButton("Delete") { _, _ ->
                status.text = "Deleted"
                Reticle.log("dialog_confirmed", mapOf("choice" to "delete"))
            }
            .setNegativeButton("Cancel") { _, _ ->
                status.text = "Cancelled"
                Reticle.log("dialog_dismissed", mapOf("choice" to "cancel"))
            }
            .show()
    }
}
