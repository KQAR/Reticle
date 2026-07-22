package dev.reticle.sample

import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/**
 * The keyboard trap, reproduced deliberately: a code field at the top and the
 * submit button pinned to the bottom of the screen, with soft-input mode
 * `adjustNothing` so the window does NOT resize when the keyboard appears —
 * exactly the real-world login layout where typing leaves the keyboard sitting
 * on top of the submit button. E2E asserts that the snapshot reports the
 * keyboard, marks the button `occluded-by:keyboard`, and that `act
 * hide-keyboard` clears the way to a successful submit.
 */
class LoginScenarioActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        @Suppress("DEPRECATION")
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 48, 48, 48)
        }

        val status = TextView(this).apply {
            text = "Enter the code"
            textSize = 20f
            tag = "login.status"
        }

        val codeField = EditText(this).apply {
            tag = "login.codeField"
            hint = "SMS code"
        }

        // Empty stretch pushes the submit button to the very bottom — under
        // where the keyboard lands.
        val spacer = android.view.View(this)

        val submit = Button(this).apply {
            text = "Log in"
            tag = "login.submitButton"
            setOnClickListener {
                status.text = "Logged in: ${codeField.text}"
                Reticle.log("login_submitted", mapOf("chars" to codeField.text.length))
            }
        }

        root.addView(status)
        root.addView(codeField)
        root.addView(spacer, LinearLayout.LayoutParams(0, 0, 1f))
        root.addView(
            submit,
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { gravity = Gravity.BOTTOM },
        )
        setContentView(root)

        Reticle.log("login_visible", emptyMap())
    }
}
