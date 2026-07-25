package dev.reticle.sample

import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/**
 * A real runtime-permission prompt: the one on-screen thing an in-process agent
 * structurally CANNOT see.
 *
 * The prompt belongs to the permission controller, another process, so it appears
 * in no window of this app and in no node of the tree. A capture taken while it is
 * up looks like an ordinary screen — every control still "tappable" — even though
 * input goes to the prompt. That is the exact silent wrongness this scenario
 * exists to expose: Reticle cannot show the prompt, but it can report that this
 * app's window no longer has focus, which is a fact and enough for an agent to
 * stop and look.
 */
class PermissionScenarioActivity : AppCompatActivity() {

    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        status = TextView(this).apply {
            text = "No prompt yet"
            textSize = 20f
            tag = "permission.status"
        }

        val trigger = Button(this).apply {
            text = "Request notifications"
            tag = "permission.trigger"
            setOnClickListener {
                Reticle.log("permission_requested", mapOf("permission" to PERMISSION))
                status.text = "Prompt requested"
                requestPermissions(arrayOf(PERMISSION), REQUEST_CODE)
            }
        }

        setContentView(
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER
                setPadding(48, 48, 48, 48)
                addView(status)
                addView(trigger)
            }
        )
        Reticle.log("permission_visible", mapOf("screen" to "permission"))
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_CODE) return
        val granted = grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED
        status.text = if (granted) "Prompt granted" else "Prompt dismissed"
        Reticle.log("permission_result", mapOf("granted" to granted))
    }

    private companion object {
        const val PERMISSION = "android.permission.POST_NOTIFICATIONS"
        const val REQUEST_CODE = 4242
    }
}
