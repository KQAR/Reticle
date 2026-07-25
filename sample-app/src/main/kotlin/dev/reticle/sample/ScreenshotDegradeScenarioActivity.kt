package dev.reticle.sample

import android.graphics.Color
import android.graphics.Paint
import android.os.Bundle
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import dev.reticle.agent.Reticle

/**
 * The two ways a screenshot lies, one per capture path.
 *
 * - A `SurfaceView` draws into its OWN surface, composited by SurfaceFlinger. The
 *   in-process capture walks the view hierarchy onto a Canvas, so that surface is
 *   simply not there — the picture comes back with a hole where the video/GL
 *   content is, and nothing about the image says so.
 * - `FLAG_SECURE` is the mirror image: the app's own Canvas draw is unaffected,
 *   but the device-level `adb exec-out screencap` returns a blanked frame.
 *
 * Either way the failure is silent, which is the problem: a blank rect reads as
 * "the app drew nothing there". The scenario exists so both degrades can be
 * *reported* instead of inferred, and asserted in the e2e.
 */
class ScreenshotDegradeScenarioActivity : AppCompatActivity() {

    private lateinit var status: TextView
    private var secure = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        status = TextView(this).apply {
            text = "Secure: off"
            textSize = 20f
            tag = "degrade.status"
        }

        // Solid magenta, so "was this captured?" is a one-pixel question.
        val surface = SurfaceView(this).apply {
            tag = "degrade.surface"
            contentDescription = "Video surface"
            holder.addCallback(object : SurfaceHolder.Callback {
                override fun surfaceCreated(holder: SurfaceHolder) = paint(holder)
                override fun surfaceChanged(holder: SurfaceHolder, f: Int, w: Int, h: Int) = paint(holder)
                override fun surfaceDestroyed(holder: SurfaceHolder) = Unit
            })
        }

        val secureToggle = Button(this).apply {
            text = "Toggle FLAG_SECURE"
            tag = "degrade.secureToggle"
            setOnClickListener {
                secure = !secure
                if (secure) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                }
                status.text = if (secure) "Secure: on" else "Secure: off"
                Reticle.log("screenshot_secure_toggled", mapOf("secure" to secure))
            }
        }

        setContentView(
            LinearLayout(this).apply {
                orientation = LinearLayout.VERTICAL
                gravity = Gravity.CENTER_HORIZONTAL
                setPadding(48, 48, 48, 48)
                addView(status)
                addView(secureToggle)
                addView(
                    surface,
                    LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 600)
                )
            }
        )
        Reticle.log("screenshot_degrade_visible", mapOf("screen" to "screenshotDegrade"))
    }

    private fun paint(holder: SurfaceHolder) {
        val canvas = holder.lockCanvas() ?: return
        canvas.drawColor(Color.MAGENTA)
        canvas.drawText(
            "SURFACE",
            32f,
            120f,
            Paint().apply { color = Color.WHITE; textSize = 72f }
        )
        holder.unlockCanvasAndPost(canvas)
    }
}
