package dev.reticle.sample

import android.app.Dialog
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.ColorDrawable
import android.os.Bundle
import android.view.Gravity
import android.view.MotionEvent
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import com.airbnb.lottie.FontAssetDelegate
import com.airbnb.lottie.LottieAnimationView
import com.airbnb.lottie.LottieDrawable
import dev.reticle.agent.Reticle

/**
 * The dialog IS a Lottie: the entire card — title, message, and both buttons —
 * is drawn by a single Lottie animation (text + shape layers). Nothing inside is
 * a native view. This is the stress case for "recognize element position and
 * content": Reticle walks view/AX trees, but a Lottie renders into one opaque
 * canvas, so the title/message/buttons baked into it are pixels, not nodes.
 */
class LottieOnlyDialogScenarioActivity : AppCompatActivity() {

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
            tag = "lottieOnly.status"
        }
        root.addView(status)
        root.addView(Button(this).apply {
            text = "Show Lottie dialog"
            tag = "lottieOnly.trigger"
            setOnClickListener {
                Reticle.log("lottie_only_opened", mapOf("kind" to "lottie-canvas"))
                showLottieDialog(status)
            }
        })
        setContentView(root)
        Reticle.log("lottie_only_visible", mapOf("screen" to "lottieOnly"))
    }

    private fun showLottieDialog(status: TextView) {
        val density = resources.displayMetrics.density
        val animation = LottieAnimationView(this).apply {
            // The whole dialog UI lives inside this one animated view.
            tag = "lottieOnly.canvas"
            // The Lottie's text layers reference a "Roboto" font; supply a system
            // typeface so lottie-android renders the baked-in text instead of
            // hunting for a bundled fonts/Roboto.ttf asset (which would crash).
            setFontAssetDelegate(object : FontAssetDelegate() {
                override fun fetchFont(fontFamily: String?): Typeface =
                    Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            })
            setAnimation("lottie_dialog.json")
            repeatCount = LottieDrawable.INFINITE
            playAnimation()
        }
        val dialog = Dialog(this).apply {
            window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            setContentView(
                animation,
                LinearLayout.LayoutParams((300 * density).toInt(), (220 * density).toInt()),
            )
            show()
        }
        // The buttons are painted by the Lottie, so there are no child views to
        // click. Like real apps that ship Lottie dialogs, the view hit-tests the
        // tap against the known button regions (composition coords) and fires the
        // matching callback — this is the handler a Reticle tap must trigger.
        animation.setOnTouchListener { view, event ->
            if (event.action != MotionEvent.ACTION_UP) return@setOnTouchListener true
            val scale = minOf(view.width / COMPOSITION_W, view.height / COMPOSITION_H)
            val offX = (view.width - COMPOSITION_W * scale) / 2f
            val offY = (view.height - COMPOSITION_H * scale) / 2f
            val cx = (event.x - offX) / scale
            val cy = (event.y - offY) / scale
            when {
                CANCEL_RECT.contains(cx, cy) -> {
                    status.text = "Cancelled"
                    Reticle.log("lottie_only_choice", mapOf("choice" to "cancel"))
                    dialog.dismiss()
                }
                DELETE_RECT.contains(cx, cy) -> {
                    status.text = "Deleted"
                    Reticle.log("lottie_only_choice", mapOf("choice" to "delete"))
                    dialog.dismiss()
                }
            }
            view.performClick()
            true
        }
    }

    /** Composition-space button hit rects (see assets/lottie_dialog.json). */
    private class CompRect(val l: Float, val t: Float, val r: Float, val b: Float) {
        fun contains(x: Float, y: Float) = x in l..r && y in t..b
    }

    private companion object {
        const val COMPOSITION_W = 300f
        const val COMPOSITION_H = 220f
        // Buttons centered at (85,170) and (215,170), each 116x46.
        val CANCEL_RECT = CompRect(27f, 147f, 143f, 193f)
        val DELETE_RECT = CompRect(157f, 147f, 273f, 193f)
    }
}
