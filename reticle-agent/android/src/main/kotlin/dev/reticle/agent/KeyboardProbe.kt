package dev.reticle.agent

import android.content.Context
import android.os.Build
import android.util.DisplayMetrics
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import dev.reticle.core.KeyboardInfo
import dev.reticle.core.Rect

/**
 * Detects the system keyboard (IME) from inside the app process. The IME is a
 * window owned by the IME *process*, so it never shows up in the
 * WindowManagerGlobal walk that SnapshotCapture does — the only in-process
 * signal is the insets it applies to the app's own windows. Snapshots carry
 * the result in ScreenInfo.keyboard so agents can see that a target is under
 * the keyboard before tapping it.
 */
internal object KeyboardProbe {

    /**
     * Probe the IME state, or null when it can't be read (no attached windows,
     * e.g. the app is backgrounded). Must run on the main thread — it reads
     * attached views' insets.
     *
     * IME insets are only dispatched to the window that is the IME *target*
     * (the focused one) — every other window keeps reporting ime hidden, and
     * which window holds focus isn't knowable from the outside (verified on a
     * real device: probing only the base window said hidden while dumpsys said
     * mInputShown=true). So probe EVERY attached root and let any window that
     * sees the keyboard win, taking the tallest reported frame.
     */
    fun probe(context: Context): KeyboardInfo? {
        val roots = ReticleWindows.rootViews().filter { it.width > 0 && it.height > 0 }
        if (roots.isEmpty()) return null
        val screen = screenSize(context)
        var best: KeyboardInfo? = null
        for (root in roots) {
            val probed = probeWindow(root, screen) ?: continue
            if (best == null ||
                (probed.visible && (probed.frame?.height ?: 0.0) > (best.frame?.height ?: 0.0))
            ) {
                if (probed.visible || best == null) best = probed
            }
        }
        return best
    }

    private fun probeWindow(root: View, screen: Pair<Int, Int>): KeyboardInfo? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val insets = root.rootWindowInsets
            if (insets != null) {
                val ime = insets.getInsets(WindowInsets.Type.ime())
                val visible = insets.isVisible(WindowInsets.Type.ime()) && ime.bottom > 0
                return KeyboardInfo(
                    visible = visible,
                    frame = if (visible) bottomAnchoredFrame(screen, ime.bottom) else null,
                )
            }
            return null
        }
        return legacyProbe(root, screen)
    }

    /**
     * Pre-R fallback: WindowInsets.Type.ime() is API 30, so infer the keyboard
     * from how much of the screen the window can't draw into. Anything past
     * [LEGACY_MIN_FRACTION] of the screen height is the IME — navigation bars
     * stay well under it.
     */
    private fun legacyProbe(root: View, screen: Pair<Int, Int>): KeyboardInfo {
        val visibleFrame = android.graphics.Rect()
        root.getWindowVisibleDisplayFrame(visibleFrame)
        val covered = screen.second - visibleFrame.bottom
        val visible = covered > screen.second * LEGACY_MIN_FRACTION
        return KeyboardInfo(
            visible = visible,
            frame = if (visible) bottomAnchoredFrame(screen, covered) else null,
        )
    }

    private fun bottomAnchoredFrame(screen: Pair<Int, Int>, imeHeight: Int): Rect =
        Rect(
            x = 0.0,
            y = (screen.second - imeHeight).toDouble(),
            width = screen.first.toDouble(),
            height = imeHeight.toDouble(),
        )

    /** Same real-metrics source SnapshotCapture.screenInfo uses. */
    private fun screenSize(context: Context): Pair<Int, Int> {
        val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val metrics = DisplayMetrics()
        @Suppress("DEPRECATION")
        wm.defaultDisplay.getRealMetrics(metrics)
        return metrics.widthPixels to metrics.heightPixels
    }

    private const val LEGACY_MIN_FRACTION = 0.15
}
