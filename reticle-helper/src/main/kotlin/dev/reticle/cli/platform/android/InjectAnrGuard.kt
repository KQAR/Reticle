package dev.reticle.cli.platform.android

import dev.reticle.cli.platform.DeviceController

/**
 * The ANR window `app inject` opens on itself: named always, closed on request.
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
 * Two halves, with deliberately different defaults:
 *
 *  - [explainKill] is ALWAYS on. It costs nothing until an injection fails, and
 *    turns a bare exception name into the system's own verdict: the pid we
 *    attached to is gone AND `dumpsys activity exit-info` reports an ANR;
 *  - [install] marks the app as being debugged (`am set-debug-app --persistent`),
 *    which makes AMS relax the input-dispatch verdict for it. This is **opt-in**,
 *    because AMS FORCE-STOPS the target when its debug marking changes: measured
 *    on an API 36 emulator, `pidof` went from 6356 to nothing, and injection then
 *    failed with an EOF handshake against a pid that no longer existed. The app
 *    has to be relaunched and injected into fresh, so the guard costs the screen
 *    the app was on — not something to spend behind a caller's back on the one
 *    command whose whole selling point is "into the process as it is running
 *    now". `app inject --restart-under-debugger` asks for it explicitly.
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

    /** A guard that was never installed: nothing to restore, nothing relaxed. */
    fun disabled(device: DeviceController): Installed = Installed(device, previous = null, active = false)

    /**
     * Mark [packageName] as the debug app, remembering whatever was set before.
     *
     * **Kills the target**: AMS force-stops the app whose debug marking changes, so
     * the caller must relaunch it and resolve a fresh pid afterwards. That is why
     * this sits behind a flag rather than running by default.
     *
     * Best-effort otherwise: a device that refuses (`SecurityException`, an OEM
     * build without the command) still gets injected, just without the relaxed ANR
     * verdict — and [explainKill] says so if it turns out to matter.
     */
    fun install(device: DeviceController, packageName: String): Installed {
        val previous = runCatching { readDebugApp(device) }.getOrNull()
        val set = runCatching { device.shell("am set-debug-app --persistent $packageName") }.getOrNull()
        val active = set?.ok == true && !set.stdout.contains("Exception") && !set.stderr.contains("Exception")
        return Installed(device, previous?.takeIf { it != packageName }, active)
    }

    /**
     * The currently marked debug app, or null when none is set.
     *
     * Read through `settings get global debug_app` rather than `dumpsys activity
     * processes`: it is one cheap row instead of a multi-megabyte dump, and the
     * dump has to be filtered on-device by a `grep` whose flags are not portable —
     * toybox's `grep -m 1` (with the space) silently produced NOTHING on the API 36
     * emulator, i.e. a read that always answered "unset" and would have cleared a
     * marking it should have restored.
     */
    private fun readDebugApp(device: DeviceController): String? =
        parseDebugApp(device.shell("settings get global debug_app", timeoutSeconds = 10).stdout)

    /**
     * The package named by the `debug_app` setting, or null for `null`/absent.
     * Split out from the device call so the parsing is testable without a device.
     */
    fun parseDebugApp(raw: String): String? {
        val value = raw.trim().lines().firstOrNull()?.trim() ?: return null
        return value.takeIf { it.isNotBlank() && it != "null" && !it.contains(' ') }
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
                    "  The app WAS marked as being debugged (`am set-debug-app`) to relax that " +
                        "verdict and the system killed it anyway, so this ROM does not honour the " +
                        "marking. Retrying will reproduce it. Injecting on a screen that is idle " +
                        "(no animation, no pending touch) gives the suspension the most headroom.\n"
                } else {
                    "  Retry with `app inject --restart-under-debugger`: it marks the app as being " +
                        "debugged for the injection, which makes AMS relax that verdict. Note the " +
                        "cost, which is why it is not the default — setting the debug app " +
                        "force-stops the target, so the app is RELAUNCHED and whatever screen it " +
                        "was on is gone.\n"
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
