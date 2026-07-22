package dev.reticle.sample

import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
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
 * hide-keyboard` clears the way to a successful submit. The code field also
 * submits on the keyboard's Done key (the common OTP pattern), which is what
 * `act type --submit` exercises.
 */
class LoginScenarioActivity : AppCompatActivity() {

    private lateinit var status: TextView
    private lateinit var codeField: EditText

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        @Suppress("DEPRECATION")
        window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 48, 48, 48)
        }

        status = TextView(this).apply {
            text = "Enter the code"
            textSize = 20f
            tag = "login.status"
        }

        codeField = EditText(this).apply {
            tag = "login.codeField"
            hint = "SMS code"
            // Submit on the keyboard's Done key too — the listener
            // `act type --submit` lands on. The bottom button stays; it is the
            // occlusion scenario the hide-keyboard E2E drives.
            imeOptions = EditorInfo.IME_ACTION_DONE
            isSingleLine = true
            setOnEditorActionListener { _, actionId, _ ->
                if (actionId == EditorInfo.IME_ACTION_DONE) {
                    submitCode()
                    true
                } else {
                    false
                }
            }
        }

        // Empty stretch pushes the submit button to the very bottom — under
        // where the keyboard lands.
        val spacer = android.view.View(this)

        val submit = Button(this).apply {
            text = "Log in"
            tag = "login.submitButton"
            setOnClickListener { submitCode() }
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

    private fun submitCode() {
        status.text = "Logged in: ${codeField.text}"
        Reticle.log("login_submitted", mapOf("chars" to codeField.text.length))
    }
}
