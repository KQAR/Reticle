package dev.reticle.agent

import android.content.Context
import android.os.Process
import android.util.Log
import dev.reticle.core.LogEntry
import dev.reticle.core.MetadataValue
import dev.reticle.core.PortMap
import java.util.ArrayDeque

/**
 * Process-wide runtime singleton: owns the localhost server lifecycle, the
 * app-authored log/metadata bridge, and the per-testId metadata registry.
 */
class ReticleRuntime private constructor() {

    @Volatile
    private var server: ReticleServer? = null

    @Volatile
    var appContext: Context? = null
        private set

    /**
     * The loopback port the server actually bound, or -1 if it isn't running.
     * Exposed so the injection bootstrap can report a concrete port back to the
     * host CLI over JDWP (the linked/ContentProvider path doesn't need it — it
     * reads the port from `/runtime`).
     */
    val boundPort: Int get() = server?.boundPort ?: -1

    /**
     * Bounded ring of the most recent app-authored log lines. Capped so a
     * long-lived process can't grow it without limit; a plain CopyOnWriteArrayList
     * also made every append an O(n) copy (O(n²) overall). Guarded by its own
     * monitor since the server handles requests on multiple worker threads.
     */
    private val logs = ArrayDeque<LogEntry>()

    /** testId -> app-attached scalar metadata. */
    private val metadataByTestId = HashMap<String, MutableMap<String, MetadataValue>>()

    val agentVersion: String get() = VERSION

    fun start(context: Context) {
        appContext = context.applicationContext

        if (System.getenv("RETICLE_DISABLED") == "1") {
            Log.i(TAG, "Reticle disabled via RETICLE_DISABLED")
            return
        }
        if (server != null) return

        // Port selection: an explicit RETICLE_PORT wins; otherwise derive a
        // stable per-app port from the package name so multiple linked apps on
        // one device don't all collide on the same fixed port (only the first to
        // start would bind it, leaving the rest silently serverless and the host
        // forward landing on the wrong app). The CLI derives the same value.
        val packageName = context.packageName
        val port = (System.getenv("RETICLE_PORT")?.toIntOrNull()) ?: PortMap.derivePort(packageName)
        val bindHost = System.getenv("RETICLE_BIND_HOST") ?: "127.0.0.1"

        val srv = ReticleServer(this)
        try {
            srv.start(port = port, bindHost = bindHost)
            server = srv
            Log.i(TAG, "Reticle started on $bindHost:$port for $packageName (pid=${Process.myPid()})")
        } catch (t: Throwable) {
            // Most often EADDRINUSE: another process already holds this port.
            // Log loudly with the package so `reticle debug logcat` can diagnose
            // a bind failure vs an unlinked agent.
            Log.e(TAG, "Reticle server FAILED to bind $bindHost:$port for $packageName (port in use?)", t)
        }
    }

    fun stop() {
        server?.stop()
        server = null
    }

    // --- App-authored bridge (the log / view-metadata bridge) ---------------

    fun log(level: String, message: String, metadata: Map<String, MetadataValue> = emptyMap()) {
        val entry = LogEntry(
            timestampMillis = System.currentTimeMillis(),
            level = level,
            message = message,
            metadata = metadata,
        )
        synchronized(logs) {
            logs.addLast(entry)
            while (logs.size > MAX_LOGS) logs.removeFirst()
        }
    }

    fun collectedLogs(): List<LogEntry> = synchronized(logs) { logs.toList() }

    fun attachMetadata(testId: String, metadata: Map<String, MetadataValue>) {
        synchronized(metadataByTestId) {
            val bag = metadataByTestId.getOrPut(testId) { HashMap() }
            bag.putAll(metadata)
        }
    }

    fun metadata(forTestId: String): Map<String, MetadataValue> =
        synchronized(metadataByTestId) {
            metadataByTestId[forTestId]?.toMap() ?: emptyMap()
        }

    companion object {
        /** Historical fixed default; real port is derived per-app via [PortMap]. */
        const val DEFAULT_PORT = PortMap.BASE_PORT
        /** App version, sourced from the repo-root VERSION file via reticle-core. */
        val VERSION: String = dev.reticle.core.RETICLE_VERSION
        private const val TAG = "Reticle"

        /** Cap on retained app-authored log lines (newest kept). */
        private const val MAX_LOGS = 1000

        @JvmStatic
        val shared: ReticleRuntime by lazy { ReticleRuntime() }
    }
}
