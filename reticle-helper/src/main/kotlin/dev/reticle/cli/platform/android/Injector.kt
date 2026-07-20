package dev.reticle.cli.platform.android

import dev.reticle.cli.CliError
import dev.reticle.cli.platform.AppInjector
import dev.reticle.cli.platform.DeviceController
import java.io.File

/**
 * Host side of the **unlinked** runtime path: get the Reticle agent running inside
 * a debuggable app that does NOT link the agent AAR, with no root and no
 * repackaging.
 *
 * The sequence, all over documented/observed primitives:
 *   1. find the running app's pid (`pidof`),
 *   2. stage the payload dex into the app's private dir (`adb push` to
 *      /data/local/tmp, then `run-as <pkg> cp` — the only way onto a private data
 *      dir without root),
 *   3. `adb forward tcp:<h> jdwp:<pid>` to reach the process's JDWP channel,
 *   4. drive [JdwpClient.inject]: load the dex with a DexClassLoader and call
 *      `Bootstrap.start()`, which starts [ReticleServer] inside the process.
 *
 * After this the app exposes the same loopback server as a linked app, so every
 * other command (`ui`, `act`, `mutate`, `debug logs`) works against it unchanged.
 */
object Injector : AppInjector {

    /** Where the payload lands inside the app sandbox; mirrors a normal dex cache. */
    private const val DEVICE_DEX_NAME = "reticle-agent-payload.jar"
    private const val STAGING_DIR = "/data/local/tmp"

    /**
     * How long to keep retrying the JDWP handshake before giving up.
     *
     * Measured on a real device, a freshly-started DEBUG process exposes a SHORT
     * JDWP accept window — handshake OK from ~pid+0.04s — that closes around
     * pid+0.5s, after which new attaches are refused (adb forwards, but the device
     * returns an empty read) until ~pid+15-16s, then accept permanently. The window
     * tracks PROCESS AGE, not foreground state (a hot start reusing an old process
     * has none). This is NOT app anti-debug: it reproduces on a sibling app sharing
     * the same React Native + lib stack, and the target's source has shielding
     * disabled (no RASP/DexGuard, no debugger-detection). The likeliest cause is
     * the RN debug startup itself holding the single per-pid JDWP consumer slot
     * while it loads/executes the dev bundle (the startup logcat is all SoLoader +
     * "ReactNative: Packager connection ..."). Either way we can't make it accept
     * sooner, so the budget must exceed the dead-zone: if [inject] misses the early
     * window it rides the ~15s out in ONE invocation instead of hard-failing. A
     * process older than the window — the common "open the app, then inject" case —
     * connects on the first attempt with no wait.
     */
    private const val HANDSHAKE_BUDGET_MS = 20_000L

    /**
     * Inject and start the runtime in [packageName]. Returns the pid and the port
     * `Bootstrap.start()` reported (negative => a `Bootstrap.ERR_*` code; the
     * caller still verifies liveness over HTTP, which is the real proof).
     */
    override fun inject(device: DeviceController, packageName: String): AppInjector.InjectResult {
        val adb = device
        val pid = adb.pidOf(packageName)
            ?: throw CliError(
                "app '$packageName' is not running. Start it first (open it, or " +
                    "`adb shell monkey -p $packageName -c android.intent.category.LAUNCHER 1`), " +
                    "then inject."
            )

        // Resolve the payload locally first — no device I/O, so it can't perturb
        // the JDWP channel we're about to open.
        val dex = locatePayloadDex()

        // Reach the process's JDWP channel over a fresh host port. Derive it off
        // the runtime port range so it won't clash with an active forward.
        val jdwpHostPort = 16000 + (pid % 1000)

        // ORDER MATTERS: open the JDWP connection BEFORE staging the dex.
        //
        // A freshly-started debug process exposes only a SHORT JDWP accept window
        // (OK ~pid+0.04s, closed by ~pid+0.5s) before it refuses new attaches for
        // ~15s (see [HANDSHAKE_BUDGET_MS] — an RN-debug-startup artifact, not app
        // anti-debug). Staging first burns that early window on `adb push` +
        // `run-as`, guaranteeing we land in the dead-zone; staging also adds device
        // I/O latency right when the window is closing. Handshaking FIRST gives the
        // best shot at the open window, and a connection held open survives the
        // dead-zone, so we stage afterwards over the live channel. When we do miss
        // the window, [connectWithHandshake] still rides the ~15s out rather than
        // failing.
        adb.removeForward(jdwpHostPort)
        val forward = adb.forwardJdwp(jdwpHostPort, pid)
        if (!forward.ok) {
            throw CliError(
                "could not forward JDWP for pid $pid: ${forward.stderr.ifBlank { "is the app debuggable?" }}\n" +
                    "  Only debuggable builds expose JDWP. A release/user build cannot be injected this way."
            )
        }
        try {
            val client = connectWithHandshake(adb, jdwpHostPort, pid)
            client.use { jdwp ->
                // Stage the payload while the JDWP connection is held open; the
                // open channel rides through the dead-zone that would refuse a
                // fresh attach started now.
                val deviceDexPath = stageDex(adb, packageName, dex)
                jdwp.negotiateIdSizes()
                val (cx, cy) = screenCenter(adb)
                val reported = jdwp.inject(deviceDexPath) {
                    // Nudge the main looper so Handler.dispatchMessage (the breakpoint)
                    // fires. The breakpoint fires when the MotionEvent is DELIVERED to
                    // the app window (posted as a main-looper message), NOT when a view
                    // acts on it — so a short SWIPE reliably drives the instrumented
                    // method WITHOUT ever firing a click handler. A tap would: the old
                    // hardcoded `input tap 540 1500` pressed real UI at a resolution-
                    // dependent point and could dismiss a dialog or submit a form. A
                    // swipe's worst case is scrolling a scrollable view slightly; it
                    // never activates a control. Coordinates are the screen center from
                    // `wm size` (resolution-agnostic), and a key event isn't usable —
                    // keys target the input-focused window, which a screen with no
                    // focusable view may not have, so they aren't delivered; a touch is
                    // coordinate-targeted and always reaches the window under the point.
                    adb.shell("input swipe $cx $cy $cx ${cy - 80} 300")
                }
                return AppInjector.InjectResult(pid, reported)
            }
        } finally {
            adb.removeForward(jdwpHostPort)
        }
    }

    /**
     * Open the JDWP socket and complete the handshake, retrying until [HANDSHAKE_BUDGET_MS].
     *
     * Two timing regimes (see [HANDSHAKE_BUDGET_MS] for the measurements):
     *  - A process older than the refuse-window connects on the first attempt.
     *  - A just-started process may be in its early accept window (catch it fast)
     *    or already past it into the ~15s dead-zone (ride it out, don't fail).
     * So we probe rapidly at first — to land the narrow early window if it's still
     * open — then keep retrying across the dead-zone until the budget elapses. Each
     * attempt re-issues the forward (remove + re-add): a forward bound onto the
     * closed transport stays a dud and won't self-heal.
     */
    /**
     * Screen center in pixels, from `wm size`. Prefers an "Override size" line
     * (the effective size) over "Physical size"; falls back to a 1080x1920 guess
     * if the output can't be parsed — the swipe only needs a point inside the
     * window, not an exact center.
     */
    private fun screenCenter(adb: DeviceController): Pair<Int, Int> {
        val out = adb.shell("wm size").stdout
        val match = Regex("""(?:Override|Physical) size:\s*(\d+)x(\d+)""").findAll(out).lastOrNull()
        val w = match?.groupValues?.getOrNull(1)?.toIntOrNull() ?: 1080
        val h = match?.groupValues?.getOrNull(2)?.toIntOrNull() ?: 1920
        return (w / 2) to (h / 2)
    }

    private fun connectWithHandshake(adb: DeviceController, hostPort: Int, pid: Int): JdwpClient {
        val debug = System.getenv("RETICLE_JDWP_DEBUG") == "1"
        val deadline = System.currentTimeMillis() + HANDSHAKE_BUDGET_MS
        var lastError: Throwable? = null
        var attempt = 0
        while (true) {
            try {
                // Re-issue the forward from the 2nd attempt on — the initial one was
                // set up by the caller, and a stale/dud forward won't self-heal.
                if (attempt > 0) {
                    adb.removeForward(hostPort)
                    adb.forwardJdwp(hostPort, pid)
                }
                val socket = java.net.Socket("127.0.0.1", hostPort)
                try {
                    val client = JdwpClient(socket)
                    client.handshake()
                    return client
                } catch (e: Throwable) {
                    // Close the socket before retrying — otherwise each of the
                    // ~20 handshake attempts across the dead-zone leaks one.
                    runCatching { socket.close() }
                    throw e
                }
            } catch (e: Throwable) {
                if (debug) System.err.println("jdwp: handshake attempt $attempt failed: ${e.javaClass.simpleName} ${e.message}")
                lastError = e
                if (System.currentTimeMillis() >= deadline) break
                // Probe fast for the first ~1s to catch the early accept window
                // before it closes, then back off to ~1s spacing to ride the
                // dead-zone out cheaply.
                Thread.sleep(if (attempt < 10) 100 else 1000)
                attempt++
            }
        }
        throw CliError(
            "JDWP channel for pid $pid never completed a handshake within ${HANDSHAKE_BUDGET_MS / 1000}s " +
                "(${lastError?.message ?: "EOF"}).\n" +
                "  Another debugger may be attached (Android Studio?). If the app was just launched," +
                " give it a moment and retry."
        )
    }

    /**
     * Resolve the injectable payload dex jar, in precedence order:
     *   1. $RETICLE_PAYLOAD_DEX (explicit override),
     *   2. the gradle build output (development),
     *   3. next to the CLI install (a shipped release — same layout as `bin/reticle`).
     */
    private fun locatePayloadDex(): File {
        // Explicit override, in precedence: the `reticle.payloadDex` system
        // property (set-able at runtime — the helper RPC uses this so a host that
        // spawns the helper from an arbitrary cwd can name the payload), then the
        // RETICLE_PAYLOAD_DEX env var.
        (System.getProperty("reticle.payloadDex") ?: System.getenv("RETICLE_PAYLOAD_DEX"))?.let {
            val f = File(it)
            if (f.isFile) return f
            throw CliError("payload dex override points to '$it' but no file is there.")
        }

        val candidates = buildList {
            // Development: gradle build output, relative to common run locations.
            val buildRel = "reticle-agent/android/build/reticle-payload/$DEVICE_DEX_NAME"
            add(File(buildRel))
            add(File(System.getProperty("user.dir"), buildRel))
            // Shipped release: alongside the installed CLI distribution.
            installRoot()?.let { add(File(it, "lib/$DEVICE_DEX_NAME")) }
        }
        return candidates.firstOrNull { it.isFile }
            ?: throw CliError(
                "payload dex '$DEVICE_DEX_NAME' not found.\n" +
                    "  Build it with: ./gradlew :reticle-agent:android:dexPayload\n" +
                    "  or point RETICLE_PAYLOAD_DEX at a prebuilt one."
            )
    }

    /** The root of the installed helper distribution, inferred from the jar location. */
    private fun installRoot(): File? = runCatching {
        val jar = File(Injector::class.java.protectionDomain.codeSource.location.toURI())
        // .../reticle-helper/lib/reticle-helper.jar -> .../reticle-helper
        jar.parentFile?.parentFile
    }.getOrNull()

    /**
     * Push [dex] to a world-readable staging path, then copy it into the app's
     * private dir as the app uid (`run-as`). Returns the in-sandbox path the
     * DexClassLoader will load. `run-as` cannot read an arbitrary host file, but
     * /data/local/tmp is readable by the app uid, so the two-step push+cp is the
     * supported non-root staging route.
     */
    private fun stageDex(adb: DeviceController, packageName: String, dex: File): String {
        val stagedHostName = "reticle-payload-${dex.length()}.jar"
        val stagingPath = "$STAGING_DIR/$stagedHostName"
        val push = adb.run("push", dex.absolutePath, stagingPath)
        if (!push.ok) throw CliError("failed to push payload dex to device: ${push.stderr}")

        // App-private code dir. code_cache exists for every app and is executable
        // for the app uid, which the DexClassLoader needs. mkdir -p is a no-op if
        // it already exists; ignore its (benign) output.
        val dataDir = "/data/data/$packageName"
        adb.runAs(packageName, "mkdir", "-p", "$dataDir/code_cache")
        val devicePath = "$dataDir/code_cache/$DEVICE_DEX_NAME"
        // Remove any prior copy first: a previous inject left it 0444 (read-only,
        // for ART's W^X policy), and `cp` cannot overwrite a read-only file —
        // re-injection would fail "Permission denied". rm in the app sandbox works
        // regardless of the file's mode.
        adb.runAs(packageName, "rm", "-f", devicePath)
        val copy = adb.runAs(packageName, "cp", stagingPath, devicePath)
        if (!copy.ok) {
            throw CliError(
                "failed to stage payload into $packageName sandbox: ${copy.stderr.ifBlank { "run-as failed" }}\n" +
                    "  The app must be debuggable for run-as to work."
            )
        }
        // Make the dex READ-ONLY. ART's W^X policy (API 26+) refuses to load a dex
        // that is writable by the loading app's uid — it throws
        // "SecurityException: Writable dex file ... is not allowed". A 0444 file
        // satisfies the policy. (The staged copy lands 0664 by default.)
        adb.runAs(packageName, "chmod", "0444", devicePath)
        // Best-effort cleanup of the world-readable staging copy.
        adb.shell("rm -f $stagingPath")
        return devicePath
    }
}
