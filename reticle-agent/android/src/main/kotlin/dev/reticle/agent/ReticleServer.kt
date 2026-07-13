package dev.reticle.agent

import android.os.Build
import android.os.Process
import android.util.Log
import dev.reticle.core.SemanticTree
import dev.reticle.core.CompactObservation
import dev.reticle.core.Endpoints
import dev.reticle.core.LogBatch
import dev.reticle.core.MutationRequest
import dev.reticle.core.ReticleJson
import dev.reticle.core.RuntimeInfo
import dev.reticle.core.UiReport
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.concurrent.ExecutorService
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/**
 * In-process HTTP server bound to loopback: a tiny raw-socket HTTP server on
 * 127.0.0.1 that the host CLI reaches through `adb forward`, which bridges the
 * device loopback to the host.
 *
 * Deliberately dependency-free (no NanoHTTPD): a hand-rolled socket server keeps
 * the AAR tiny.
 */
class ReticleServer(private val runtime: ReticleRuntime) {

    @Volatile
    private var serverSocket: ServerSocket? = null

    @Volatile
    private var running = false

    @Volatile
    var boundPort: Int = 0
        private set

    @Volatile
    private var workers: ExecutorService? = null

    fun start(port: Int, bindHost: String) {
        stop()
        val address = InetAddress.getByName(bindHost)
        val socket = ServerSocket(port, 50, address)
        serverSocket = socket
        boundPort = socket.localPort
        running = true

        // Bounded worker pool with backpressure: when all workers are busy,
        // CallerRunsPolicy runs the request on the accept loop itself, which
        // stops accepting new connections until a worker frees up. This caps
        // the thread count instead of spawning one unbounded thread per client.
        workers = ThreadPoolExecutor(
            0, MAX_WORKERS, 30L, TimeUnit.SECONDS,
            SynchronousQueue(),
            { r -> Thread(r, "reticle-worker").apply { isDaemon = true } },
            ThreadPoolExecutor.CallerRunsPolicy(),
        )

        thread(name = "reticle-server", isDaemon = true) {
            while (running) {
                val client = try {
                    socket.accept()
                } catch (t: Throwable) {
                    if (running) Log.w(TAG, "accept failed", t)
                    break
                }
                val pool = workers
                if (pool != null) pool.execute { handle(client) } else handle(client)
            }
        }
    }

    fun stop() {
        running = false
        try {
            serverSocket?.close()
        } catch (_: Throwable) {
        }
        serverSocket = null
        workers?.shutdownNow()
        workers = null
    }

    private fun handle(client: Socket) {
        client.use { socket ->
            try {
                // Bound how long a client may hold this worker: a peer that
                // connects and never finishes sending a request would otherwise
                // block a worker forever (read() has no timeout by default).
                socket.soTimeout = SOCKET_READ_TIMEOUT_MS
                // Read the request line + headers byte-wise, then the body as
                // exactly Content-Length BYTES. A char-based reader would read
                // Content-Length *chars*, which over-reads for multibyte UTF-8
                // bodies (e.g. Chinese text) and blocks until the socket times
                // out — even though the request was complete.
                val input = socket.getInputStream()
                val out = socket.getOutputStream()
                val requestLine = readHeaderLine(input) ?: return
                val parts = requestLine.split(" ")
                if (parts.size < 2) return
                val method = parts[0]
                val path = parts[1].substringBefore('?')

                var contentLength = 0
                while (true) {
                    val line = readHeaderLine(input) ?: break
                    if (line.isEmpty()) break
                    if (line.lowercase().startsWith("content-length:")) {
                        contentLength = line.substringAfter(":").trim().toIntOrNull() ?: 0
                    }
                }

                // Bound the body BEFORE allocating: contentLength is
                // client-controlled, and ByteArray(contentLength) with a huge or
                // negative value would OOM or crash the host app's process.
                if (contentLength < 0) {
                    writeText(out, 400, "invalid Content-Length")
                    return
                }
                if (contentLength > MAX_BODY_BYTES) {
                    writeText(out, 413, "request body too large (max $MAX_BODY_BYTES bytes)")
                    return
                }

                val body = if (contentLength > 0) {
                    val bytes = ByteArray(contentLength)
                    var read = 0
                    while (read < contentLength) {
                        val n = input.read(bytes, read, contentLength - read)
                        if (n < 0) break
                        read += n
                    }
                    String(bytes, 0, read, StandardCharsets.UTF_8)
                } else ""

                try {
                    route(out, method, path, body)
                } catch (t: Throwable) {
                    // A failed route (malformed MUTATE body, capture blowing up
                    // mid-walk) must still answer: silently closing the socket
                    // gives the CLI an undiagnosable "empty reply from server".
                    Log.w(TAG, "route failed: $method $path", t)
                    runCatching {
                        writeText(out, 500, "${t.javaClass.simpleName}: ${t.message ?: "internal error"}")
                    }
                }
            } catch (t: Throwable) {
                Log.w(TAG, "request handling failed", t)
            }
        }
    }

    /**
     * Read one CRLF-terminated header line as ASCII bytes (headers are ASCII).
     * Returns the line without the trailing CRLF, or null at end of stream.
     */
    private fun readHeaderLine(input: java.io.InputStream): String? {
        val sb = StringBuilder()
        var sawAny = false
        while (true) {
            val b = input.read()
            if (b < 0) return if (sawAny) sb.toString() else null
            sawAny = true
            if (b == '\n'.code) break
            if (b != '\r'.code) sb.append(b.toChar())
            // A line that never ends would otherwise grow this buffer until the
            // socket timeout; past any sane header size, give up on the request.
            if (sb.length > MAX_HEADER_LINE_BYTES) {
                throw java.io.IOException("header line exceeds $MAX_HEADER_LINE_BYTES bytes")
            }
        }
        return sb.toString()
    }

    private fun route(out: OutputStream, method: String, path: String, body: String) {
        val context = runtime.appContext
        if (context == null) {
            writeText(out, 503, "agent context unavailable")
            return
        }
        when {
            method == "GET" && path == Endpoints.RUNTIME -> {
                val info = RuntimeInfo(
                    packageName = context.packageName,
                    processName = currentProcessName(),
                    pid = Process.myPid(),
                    sdkInt = Build.VERSION.SDK_INT,
                    agentVersion = runtime.agentVersion,
                    port = boundPort,
                )
                writeJson(out, ReticleJson.compact.encodeToString(RuntimeInfo.serializer(), info))
            }

            method == "GET" && path == Endpoints.SNAPSHOT -> {
                val snapshot = SnapshotCapture(context).capture()
                writeJson(out, ReticleJson.compact.encodeToString(dev.reticle.core.Snapshot.serializer(), snapshot))
            }

            method == "GET" && path == Endpoints.REPORT -> {
                val snapshot = SnapshotCapture(context).capture()
                val report = UiReport.from(snapshot)
                writeJson(out, ReticleJson.compact.encodeToString(UiReport.serializer(), report))
            }

            method == "GET" && path == Endpoints.SEMANTICS -> {
                val snapshot = SnapshotCapture(context).capture()
                val tree = SemanticTree.build(snapshot)
                writeJson(out, ReticleJson.compact.encodeToString(SemanticTree.serializer(), tree))
            }

            method == "GET" && path == Endpoints.COMPACT -> {
                val snapshot = SnapshotCapture(context).capture()
                val compact = CompactObservation.from(snapshot)
                writeJson(out, ReticleJson.compact.encodeToString(CompactObservation.serializer(), compact))
            }

            method == "GET" && path == Endpoints.LOGS -> {
                val batch = LogBatch(runtime.collectedLogs())
                writeJson(out, ReticleJson.compact.encodeToString(LogBatch.serializer(), batch))
            }

            method == "GET" && path == Endpoints.SCREENSHOT -> {
                val png = ScreenshotCapture(context).capturePng()
                if (png == null) {
                    writeText(out, 500, "screenshot unavailable")
                } else {
                    writeBytes(out, 200, "image/png", png)
                }
            }

            method == "POST" && path == Endpoints.MUTATE -> {
                val request = ReticleJson.compact.decodeFromString(MutationRequest.serializer(), body)
                val result = MutationEngine(context).apply(request)
                writeJson(out, ReticleJson.compact.encodeToString(dev.reticle.core.MutationResult.serializer(), result))
            }

            method == "POST" && path == Endpoints.CLIPBOARD -> {
                // Body is the raw UTF-8 text to place on the clipboard (no JSON
                // wrapper — avoids a second layer of escaping for arbitrary text).
                if (ClipboardWriter(context).set(body)) {
                    writeText(out, 200, "ok")
                } else {
                    writeText(out, 500, "clipboard unavailable")
                }
            }

            else -> writeText(out, 404, "no route for $method $path")
        }
    }

    // --- HTTP writers -----------------------------------------------------

    private fun writeJson(out: OutputStream, json: String) {
        writeBytes(out, 200, "application/json; charset=utf-8", json.toByteArray(StandardCharsets.UTF_8))
    }

    private fun writeText(out: OutputStream, status: Int, message: String) {
        writeBytes(out, status, "text/plain; charset=utf-8", message.toByteArray(StandardCharsets.UTF_8))
    }

    private fun writeBytes(out: OutputStream, status: Int, contentType: String, payload: ByteArray) {
        val header = buildString {
            append("HTTP/1.1 ").append(status).append(' ').append(statusText(status)).append("\r\n")
            append("Content-Type: ").append(contentType).append("\r\n")
            append("Content-Length: ").append(payload.size).append("\r\n")
            append("Connection: close\r\n")
            append("\r\n")
        }
        out.write(header.toByteArray(StandardCharsets.UTF_8))
        out.write(payload)
        out.flush()
    }

    private fun statusText(status: Int): String = when (status) {
        200 -> "OK"
        400 -> "Bad Request"
        404 -> "Not Found"
        413 -> "Payload Too Large"
        500 -> "Internal Server Error"
        503 -> "Service Unavailable"
        else -> "OK"
    }

    private fun currentProcessName(): String {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                android.app.Application.getProcessName()
            } else {
                BufferedReader(InputStreamReader(java.io.FileInputStream("/proc/self/cmdline")))
                    .use { it.readLine()?.trim { c -> c.code == 0 } ?: "?" }
            }
        } catch (_: Throwable) {
            "?"
        }
    }

    private companion object {
        const val TAG = RETICLE_LOG_TAG
        const val MAX_WORKERS = 16
        const val SOCKET_READ_TIMEOUT_MS = 15_000

        // Requests are small JSON (MUTATE) or clipboard text; 4 MiB is generous.
        const val MAX_BODY_BYTES = 4 * 1024 * 1024
        const val MAX_HEADER_LINE_BYTES = 16 * 1024
    }
}
