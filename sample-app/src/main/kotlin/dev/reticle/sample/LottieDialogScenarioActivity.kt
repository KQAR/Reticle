package dev.reticle.sample

import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import com.airbnb.lottie.LottieAnimationView
import com.airbnb.lottie.LottieDrawable
import dev.reticle.agent.Reticle

/**
 * A native dialog whose content includes a *real* Lottie animation view. From
 * Reticle's side the `LottieAnimationView` is an opaque animated surface (no
 * text), so this scenario probes whether the recognizable elements around it —
 * the dialog title, the message, and the button — are still captured with the
 * right content and frames while a hardware-accelerated animation plays.
 */
class LottieDialogScenarioActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 48)
        }

        val status = TextView(this).apply {
            text = "Idle"
            textSize = 20f
            tag = "lottieDialog.status"
        }

        val trigger = Button(this).apply {
            text = "Show status dialog"
            tag = "lottieDialog.trigger"
            setOnClickListener {
                Reticle.log("lottie_dialog_opened", mapOf("kind" to "native"))
                showLottieDialog(status)
            }
        }

        root.addView(status)
        root.addView(trigger)
        setContentView(root)

        Reticle.log("lottie_dialog_visible", mapOf("screen" to "lottieDialog"))
    }

    private fun showLottieDialog(status: TextView) {
        val density = resources.displayMetrics.density
        fun dp(value: Int): Int = (value * density).toInt()

        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(24), dp(24), dp(24), dp(8))
        }

        val animation = LottieAnimationView(this).apply {
            tag = "lottieDialog.animation"
            setAnimation("lottie_anim.json")
            repeatCount = LottieDrawable.INFINITE
            playAnimation()
            layoutParams = LinearLayout.LayoutParams(dp(96), dp(96))
        }

        val message = TextView(this).apply {
            text = "Processing your request..."
            textSize = 16f
            tag = "lottieDialog.message"
            setPadding(0, dp(16), 0, 0)
        }

        content.addView(animation)
        content.addView(message)

        AlertDialog.Builder(this)
            .setTitle("Please wait")
            .setView(content)
            .setPositiveButton("Done") { _, _ ->
                status.text = "Done"
                Reticle.log("lottie_dialog_confirmed", mapOf("choice" to "done"))
            }
            .show()
    }
}
