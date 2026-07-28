package dev.reticle.cli

import dev.reticle.cli.platform.DeviceController

/**
 * Watches the system Toast Queue across an action, so a gesture the app answers
 * with a toast stops reading as a gesture that did nothing. See [ToastQueue] for
 * what the queue can and cannot say.
 *
 * **Why a background thread rather than a poll in line.** A toast is enqueued
 * synchronously inside the click handler — within ~100ms of the tap — and then
 * sits in the queue for its whole 2s/3.5s on screen. One sample would usually
 * catch it, but "usually" is the property this project does not accept, and a
 * blocking sweep would charge every act the full window even when no toast was
 * ever raised (the overwhelmingly common case).
 *
 * So the samples ride along with work the action was already doing. The schedule
 * is front-dense and then backs off — [DELAYS_MS] — because the event is
 * overwhelmingly likely at the start and the tail is only there for a toast that
 * waits on a network round trip. Each sample costs ~25ms of `adb shell` and
 * returns nothing at all when the queue is empty (device-side `grep`), so the
 * whole schedule is ~150ms of device time spent while the caller is blocked on a
 * settle, a `--verify` poll, or a trace capture anyway.
 *
 * [stop] takes whatever has been seen and waits at most [JOIN_GRACE_MS] for a
 * sample already in flight, so a fast action pays a bounded cost rather than the
 * schedule's full length.
 *
 * What this does NOT see, and says so rather than implying otherwise: a toast
 * raised later than the action's own duration plus the tail of this schedule
 * (chain an `act wait` and read the next result), and a toast raised by ANOTHER
 * process — those are filtered out by package on purpose, since attributing the
 * system's "Screenshot saved" to the app under test would be a wrong claim.
 */
internal class ToastProbe private constructor(
    private val device: DeviceController,
    private val packageName: String,
) {

    private val seen = LinkedHashMap<String, ToastQueue.Sighting>()
    @Volatile private var stopping = false
    private lateinit var worker: Thread

    private fun launch() {
        worker = Thread {
            for (delay in DELAYS_MS) {
                if (stopping) return@Thread
                try {
                    Thread.sleep(delay)
                } catch (_: InterruptedException) {
                    return@Thread
                }
                if (stopping) return@Thread
                sample()
            }
        }.apply {
            isDaemon = true
            name = "reticle-toast-probe"
            start()
        }
    }

    private fun sample() {
        val result = runCatching { device.shell(ToastQueue.COMMAND) }.getOrNull() ?: return
        // grep exits 1 with no match, which is the normal case — read stdout
        // regardless of the exit code rather than treating "no toast" as an error.
        val sightings = ToastQueue.parse(result.stdout, packageName)
        synchronized(seen) {
            for (sighting in sightings) {
                if (sighting.isSystemToast) continue
                seen.putIfAbsent(sighting.identity, sighting)
            }
        }
    }

    /**
     * Stop sampling and return the distinct toasts seen, in the order raised.
     *
     * The last sample is taken HERE, synchronously, when nothing has been seen
     * yet — and it is the one that matters most. Measured on an API 36 emulator:
     * resolving a selector and confirming its rect settled eats ~250ms before the
     * touch is even synthesized, so the front of the schedule can run out before
     * the tap lands and every sample comes back empty on a toast that is about to
     * appear. At stop time the opposite is true: the gesture has landed, and a
     * toast raised by it is 2s (or 3.5s) into a life it has barely started.
     *
     * Costs one ~25ms `adb shell` on an action that saw no toast, which is the
     * price of the check not being a coin flip.
     */
    fun stop(): List<ToastQueue.Sighting> {
        stopping = true
        runCatching { worker.join(JOIN_GRACE_MS) }
        if (synchronized(seen) { seen.isEmpty() }) sample()
        return synchronized(seen) { seen.values.toList() }
    }

    companion object {
        /**
         * Cumulative sleeps between samples: dense where the toast almost always
         * is, sparse in the tail. ~1.3s of coverage for ~150ms of device time.
         */
        private val DELAYS_MS = longArrayOf(60, 80, 100, 200, 400, 500)

        /** Longest an action will wait for a sample already in flight. */
        private const val JOIN_GRACE_MS = 250L

        /**
         * Start watching, or return null when watching is off. Best-effort by
         * construction: a probe that cannot start must never fail the action it
         * was only observing.
         */
        fun start(device: DeviceController, packageName: String, enabled: Boolean): ToastProbe? {
            if (!enabled) return null
            return runCatching {
                ToastProbe(device, packageName).also { it.launch() }
            }.getOrNull()
        }
    }
}
