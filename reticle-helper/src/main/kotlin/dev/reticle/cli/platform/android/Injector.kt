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
    private const val HANDSHAKE_ATTEMPTS = 4

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

        val dex = locatePayloadDex()
        val deviceDexPath = stageDex(adb, packageName, dex)

        // Reach the process's JDWP channel over a fresh host port. Derive it off
        // the runtime port range so it won't clash with an active forward.
        val jdwpHostPort = 16000 + (pid % 1000)

        // ADB allows only ONE JDWP consumer per pid, and a fresh `jdwp:` forward
        // has a brief readiness window — connecting too early (or onto a stale
        // forward from a prior run) yields an immediate EOF on the handshake. The
        // connect+handshake is retried; the injection proper is NOT (a failure
        // there is real and must surface, not be retried as if it were a race).
        adb.removeForward(jdwpHostPort)
        val forward = adb.forwardJdwp(jdwpHostPort, pid)
        if (!forward.ok) {
            throw CliError(
                "could not forward JDWP for pid $pid: ${forward.stderr.ifBlank { "is the app debuggable?" }}\n" +
                    "  Only debuggable builds expose JDWP. A release/user build cannot be injected this way."
            )
        }
        try {
            val client = connectWithHandshake(jdwpHostPort, pid)
            client.use { jdwp ->
                jdwp.negotiateIdSizes()
                val reported = jdwp.inject(deviceDexPath) {
                    // The event fires when the target next runs the instrumented
                    // method on a live Java frame (the only state ART allows
                    // InvokeMethod from). A real tap drives the UI through it.
                    adb.shell("input keyevent 0")
                    adb.shell("input tap 540 1500")
                }
                return AppInjector.InjectResult(pid, reported)
            }
        } finally {
            adb.removeForward(jdwpHostPort)
        }
    }

    /** Open the JDWP socket and complete the handshake, retrying the EOF race. */
    private fun connectWithHandshake(hostPort: Int, pid: Int): JdwpClient {
        val debug = System.getenv("RETICLE_JDWP_DEBUG") == "1"
        var lastError: Throwable? = null
        repeat(HANDSHAKE_ATTEMPTS) { attempt ->
            try {
                Thread.sleep(250)
                val client = JdwpClient(java.net.Socket("127.0.0.1", hostPort))
                client.handshake()
                return client
            } catch (e: Throwable) {
                if (debug) System.err.println("jdwp: handshake attempt $attempt failed: ${e.javaClass.simpleName} ${e.message}")
                lastError = e
                Thread.sleep(400)
            }
        }
        throw CliError(
            "JDWP channel for pid $pid never completed a handshake after $HANDSHAKE_ATTEMPTS tries " +
                "(${lastError?.message ?: "EOF"}).\n" +
                "  Another debugger may be attached (Android Studio?), or the app just started — retry."
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
