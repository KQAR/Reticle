package dev.reticle.agent

import android.content.Context
import android.os.Process
import android.util.Log
import dev.reticle.core.LogEntry
import dev.reticle.core.MetadataValue
import java.util.concurrent.CopyOnWriteArrayList

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

    private val logs = CopyOnWriteArrayList<LogEntry>()

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

        val port = (System.getenv("RETICLE_PORT")?.toIntOrNull()) ?: DEFAULT_PORT
        val bindHost = System.getenv("RETICLE_BIND_HOST") ?: "127.0.0.1"

        val srv = ReticleServer(this)
        try {
            srv.start(port = port, bindHost = bindHost)
            server = srv
            Log.i(TAG, "Reticle started on $bindHost:$port (pid=${Process.myPid()})")
        } catch (t: Throwable) {
            Log.e(TAG, "Reticle server failed to start on $bindHost:$port", t)
        }
    }

    fun stop() {
        server?.stop()
        server = null
    }

    // --- App-authored bridge (the log / view-metadata bridge) ---------------

    fun log(level: String, message: String, metadata: Map<String, MetadataValue> = emptyMap()) {
        logs.add(
            LogEntry(
                timestampMillis = System.currentTimeMillis(),
                level = level,
                message = message,
                metadata = metadata,
            )
        )
    }

    fun collectedLogs(): List<LogEntry> = logs.toList()

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
        const val DEFAULT_PORT = 8765
        const val VERSION = "0.1.0"
        private const val TAG = "Reticle"

        @JvmStatic
        val shared: ReticleRuntime by lazy { ReticleRuntime() }
    }
}
