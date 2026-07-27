package dev.reticle.cli.platform.android

import dev.reticle.cli.platform.DeviceController

/**
 * The ANR window `app inject` opens on itself, closed and — when it still
 * happens — named.
 *
 * Injection has two requirements that fight each other on a physical device:
 *
 *  1. the app's main looper has to RUN, or the instrumented method
 *     (`Handler.dispatchMessage`) never fires and there is no thread to inject
 *     on. The injector guarantees that by nudging input (a short swipe);
 *  2. once the breakpoint fires, JDWP SUSPENDS the main thread for as long as
 *     the payload dex takes to load and start.
 *
 * Any MotionEvent still queued — including the nudge that fired the breakpoint —
 * goes unconsumed for the whole suspension. Past Android's 5s input-dispatch
 * timeout the system kills the process with `reason=6 (ANR)`, the JDWP channel
 * dies mid-injection, and the injector sees a bare `EOFException` — which reads
 * like a transient glitch and invites a pointless retry. Measured on a physical
 * Android 15 device: one minimal swipe, sent once, was enough, because the
 * post-breakpoint work by itself outran 5s on that hardware.
 *
 * Two halves, both here:
 *
 *  - [install] marks the app as being debugged (`am set-debug-app --persistent`),
 *    which makes AMS relax the input-dispatch verdict for it, and [Installed.restore]
 *    puts the previous value back (or clears it) on every exit path. Without `-w`
 *    the app does NOT wait for a debugger, so this is safe non-interactively. This
 *    removes the race rather than papering over it;
 *  - [explainKill] classifies the aftermath when the guard did not hold (an OEM
 *    ROM that ignores `set-debug-app`, a `shell` uid without the permission): the
 *    pid we attached to is gone, and `dumpsys activity exit-info` says ANR. That
 *    is a verdict the caller can act on, unlike an exception name.
 */
internal object InjectAnrGuard {

    /** A debug-app marking that is in place and knows how to undo itself. */
    internal class Installed(
        private val device: DeviceController,
        private val previous: String?,
        /** False when the device refused the marking — nothing to undo. */
        val active: Boolean,
    ) {
        fun restore() {
            if (!active) return
            runCatching {
                if (previous != null) device.shell("am set-debug-app --persistent $previous")
                else device.shell("am clear-debug-app")
            }
        }
    }

    /**
     * Mark [packageName] as the debug app for the duration of an injection,
     * remembering whatever was set before.
     *
     * Best-effort by construction: a device that refuses (`SecurityException`, an
     * OEM build without the command) still gets injected, just without the
     * relaxed ANR verdict — the same behaviour as before this guard existed. The
     * failure is reported by [explainKill] if it turns out to matter.
     */
    fun install(device: DeviceController, packageName: String): Installed {
        val previous = runCatching { readDebugApp(device) }.getOrNull()
        val set = runCatching { device.shell("am set-debug-app --persistent $packageName") }.getOrNull()
        val active = set?.ok == true && !set.stdout.contains("Exception") && !set.stderr.contains("Exception")
        return Installed(device, previous?.takeIf { it != packageName }, active)
    }

    /** Current `mDebugApp`, or null when none is set / it can't be read. */
    private fun readDebugApp(device: DeviceController): String? =
        parseDebugApp(device.shell("dumpsys activity processes | grep -m 1 mDebugApp", timeoutSeconds = 15).stdout)

    /**
     * The package named by AMS's `mDebugApp=` field, or null for `null`/absent.
     * Split out from the device call so the parsing is testable without a device.
     */
    fun parseDebugApp(dumpsys: String): String? {
        val value = Regex("""mDebugApp=(\S+)""").find(dumpsys)?.groupValues?.get(1) ?: return null
        return value.takeIf { it != "null" && it.isNotBlank() }
    }

    /**
     * Explain a mid-injection failure when the app was killed under us, or null
     * when it was not (leave the original error alone — misattributing a real
     * JDWP bug to an ANR would be worse than the bare exception).
     *
     * The evidence is deliberately two-sided: the pid we attached to is no longer
     * the app's pid (or the app is gone), AND the system's own exit record says
     * ANR. Either alone would guess.
     */
    fun explainKill(
        device: DeviceController,
        packageName: String,
        attachedPid: Int,
        guardActive: Boolean,
    ): String? {
        val nowPid = runCatching { device.pidOf(packageName) }.getOrNull()
        if (nowPid == attachedPid) return null
        val exitInfo = runCatching {
            device.shell("dumpsys activity exit-info $packageName", timeoutSeconds = 20).stdout
        }.getOrNull().orEmpty()
        val anr = anrExit(exitInfo, attachedPid) ?: return null
        return buildString {
            append("the app was killed by the system during injection — ANR: ")
            append(anr)
            append(".\n")
            append(
                "  Injection suspends the main thread over JDWP while the payload loads; any input " +
                    "event queued at that moment (including the nudge that triggers the injection) " +
                    "goes unconsumed past Android's 5s input-dispatch timeout.\n"
            )
            append(
                if (guardActive) {
                    "  Reticle marked the app as being debugged (`am set-debug-app`) to relax that " +
                        "verdict and the system killed it anyway, so this ROM does not honour the " +
                        "marking. Retrying will reproduce it. Injecting on a screen that is idle " +
                        "(no animation, no pending touch) gives the suspension the most headroom.\n"
                } else {
                    "  Reticle could not mark the app as being debugged on this device, so nothing " +
                        "relaxed the verdict. Try it by hand:\n" +
                        "    adb shell am set-debug-app --persistent $packageName\n" +
                        "    reticle app inject --package $packageName\n" +
                        "    adb shell am clear-debug-app\n"
                }
            )
            append("  Do NOT nudge the app in a loop while injecting: a queued touch is exactly what trips this.")
        }
    }

    /**
     * The `description=` of an `ApplicationExitInfo` record that reports an ANR
     * (`reason=6`), preferring the record for [attachedPid]. Null when the exit
     * records show no ANR — the app died of something else, or `exit-info` is
     * unavailable (pre-Android-11), and we must not claim otherwise.
     */
    fun anrExit(exitInfo: String, attachedPid: Int? = null): String? {
        val records = exitInfo.lineSequence()
            .filter { it.contains("reason=6") && it.contains("ANR") }
            .toList()
        if (records.isEmpty()) return null
        val record = attachedPid
            ?.let { pid -> records.firstOrNull { it.contains("pid=$pid ") || it.contains("pid=$pid,") } }
            ?: records.first()
        val description = Regex("""description=(.*?)(?:\s+process=|\)\s*$|$)""")
            .find(record)?.groupValues?.get(1)?.trim()?.trim(')')
        return description?.takeIf { it.isNotBlank() } ?: "input dispatching timed out while the main thread was suspended"
    }
}
