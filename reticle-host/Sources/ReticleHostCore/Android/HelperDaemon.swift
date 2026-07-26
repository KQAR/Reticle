import Darwin
import Foundation

/// Resident per-device helper daemon: owns one long-lived helper backend and
/// serves its JSONL RPC over a Unix-domain socket, so one-shot CLI commands
/// skip the per-command helper spawn. Exits after `idleTimeout` with no
/// connected clients and no requests, unlinking its socket — no garbage left.
final class HelperDaemonServer: @unchecked Sendable {
    struct Info {
        let version: String
        let helperPath: String
        let helperMtime: Int
    }

    private let socketPath: String
    private let backend: HelperCalling
    private let info: Info
    private let idleTimeout: TimeInterval
    /// Backend liveness probe; when it reports false after a failed call, the
    /// daemon exits so the next command spawns a fresh daemon + helper.
    private let backendAlive: @Sendable () -> Bool

    private var listenFd: Int32 = -1
    private let state = NSLock() // guards the three fields below
    private var activeConnections = 0
    private var lastActivity = Date()
    private var stopped = false
    private let stopSem = DispatchSemaphore(value: 0)

    init(
        socketPath: String,
        backend: HelperCalling,
        info: Info,
        idleTimeout: TimeInterval,
        backendAlive: @escaping @Sendable () -> Bool = { true }
    ) {
        self.socketPath = socketPath
        self.backend = backend
        self.info = info
        self.idleTimeout = idleTimeout
        self.backendAlive = backendAlive
    }

    /// Binds the socket and starts the accept + idle-watch threads. Throws when
    /// another live daemon already owns the socket (the spawn-race loser path);
    /// a stale socket file left by a crash is unlinked and rebound.
    func start() throws {
        var addr = try UnixSocket.makeAddress(socketPath)
        if FileManager.default.fileExists(atPath: socketPath) {
            if let probe = UnixSocket.connect(socketPath) {
                close(probe)
                throw HelperError("another helper daemon is already listening on \(socketPath)")
            }
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperError("socket() failed: errno \(errno)") }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let err = errno
            close(fd)
            throw HelperError("bind(\(socketPath)) failed: errno \(err)")
        }
        guard listen(fd, 8) == 0 else {
            let err = errno
            close(fd)
            try? FileManager.default.removeItem(atPath: socketPath)
            throw HelperError("listen(\(socketPath)) failed: errno \(err)")
        }
        listenFd = fd
        Thread { [weak self] in self?.acceptLoop() }.start()
        Thread { [weak self] in self?.idleLoop() }.start()
    }

    /// Blocks until `stop()` — the daemon main's park.
    func run() {
        stopSem.wait()
    }

    /// Idempotent shutdown: close the listener, unlink the socket, release
    /// `run()`. In-flight connections finish on their own threads.
    func stop() {
        state.lock()
        if stopped {
            state.unlock()
            return
        }
        stopped = true
        state.unlock()
        if listenFd >= 0 {
            close(listenFd)
            listenFd = -1
        }
        try? FileManager.default.removeItem(atPath: socketPath)
        stopSem.signal()
    }

    var isStopped: Bool {
        state.lock()
        defer { state.unlock() }
        return stopped
    }

    // MARK: - Loops

    private func acceptLoop() {
        while true {
            let clientFd = accept(listenFd, nil, nil)
            guard clientFd >= 0 else {
                if errno == EINTR { continue }
                return // listener closed by stop()
            }
            state.lock()
            if stopped {
                state.unlock()
                close(clientFd)
                return
            }
            activeConnections += 1
            lastActivity = Date()
            state.unlock()
            Thread { [weak self] in self?.serve(clientFd: clientFd) }.start()
        }
    }

    private func idleLoop() {
        let tick = max(0.05, min(idleTimeout / 4, 15))
        while !isStopped {
            Thread.sleep(forTimeInterval: tick)
            state.lock()
            let idle = activeConnections == 0 && Date().timeIntervalSince(lastActivity) >= idleTimeout
            state.unlock()
            if idle {
                FileHandle.standardError.write(
                    Data("reticle helper-daemon: idle for \(Int(idleTimeout))s, exiting\n".utf8))
                stop()
                return
            }
        }
    }

    private func serve(clientFd: Int32) {
        defer {
            close(clientFd)
            state.lock()
            activeConnections -= 1
            lastActivity = Date()
            state.unlock()
        }
        let reader = FdLineReader(fd: clientFd)
        while case .line(let line) = reader.nextLine() {
            state.lock()
            lastActivity = Date()
            state.unlock()
            guard !line.isEmpty else { continue }
            let (response, exitAfterReply) = respond(to: line)
            if let data = try? JSONSerialization.data(withJSONObject: response) {
                UnixSocket.writeAll(clientFd, data + Data("\n".utf8))
            }
            state.lock()
            lastActivity = Date()
            state.unlock()
            if exitAfterReply {
                stop()
                return
            }
        }
    }

    /// Handles one request frame: `helperd/*` control methods locally, all else
    /// forwarded to the backend. Returns the response object and whether the
    /// daemon should exit once the reply is written.
    private func respond(to line: String) -> ([String: Any], exitAfterReply: Bool) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let method = obj["method"] as? String else {
            return (["id": NSNull(), "ok": false, "error": "malformed request frame"], false)
        }
        let id = obj["id"] ?? NSNull()
        switch method {
        case "helperd/info":
            return ([
                "id": id, "ok": true,
                "result": [
                    "version": info.version,
                    "helperPath": info.helperPath,
                    "helperMtime": info.helperMtime,
                    "pid": Int(getpid()),
                ],
            ], false)
        case "helperd/shutdown":
            return (["id": id, "ok": true, "result": ["stopping": true]], true)
        default:
            let params = (obj["params"] as? [String: Any]) ?? [:]
            do {
                let result = try backend.call(method, params)
                return (["id": id, "ok": true, "result": result], false)
            } catch {
                // A dead helper can't serve anyone: reply, then exit so the
                // next command brings up a fresh daemon instead of hitting a
                // zombie forever.
                let dead = !backendAlive()
                return (["id": id, "ok": false, "error": "\(error)"], dead)
            }
        }
    }
}

/// `reticle helper-daemon --socket <path> [--helper <path>] [--idle-timeout <s>]`
/// — the resident process behind the CLI's hot path. Spawned automatically by
/// `HelperDaemonLauncher`; running it by hand is only for debugging.
func runHelperDaemon(_ args: Args) -> Int32 {
    guard let socketPath = args.option("socket"), socketPath != "true" else {
        FileHandle.standardError.write(Data("usage: reticle helper-daemon --socket <path> [--helper <path>] [--idle-timeout <seconds>]\n".utf8))
        return 2
    }
    guard let helper = resolveHelper(args) else {
        FileHandle.standardError.write(Data("could not find the reticle helper; set RETICLE_HELPER or pass --helper\n".utf8))
        return 2
    }
    let idle = TimeInterval(args.option("idle-timeout")
        ?? ProcessInfo.processInfo.environment["RETICLE_HELPERD_IDLE"]
        ?? "") ?? Helperd.defaultIdleSeconds

    // Detach from the invoking command's session so terminal signals (the
    // user's Ctrl-C on some later command) never tear the daemon down.
    setsid()

    let helperClient = HelperClient(
        launcher: helper,
        javaHome: ProcessInfo.processInfo.environment["JAVA_HOME"]
    )
    do {
        try helperClient.start()
    } catch {
        FileHandle.standardError.write(Data("failed to start helper '\(helper)': \(error)\n".utf8))
        return 1
    }

    let server = HelperDaemonServer(
        socketPath: socketPath,
        backend: helperClient,
        info: .init(
            version: ReticleCLI.version,
            helperPath: helper,
            helperMtime: HelperDaemonLauncher.helperMtime(helper)
        ),
        idleTimeout: idle,
        backendAlive: { [weak helperClient] in helperClient?.isRunning ?? false }
    )
    do {
        try server.start()
    } catch {
        // Includes the spawn-race loser: another daemon won the bind — fine,
        // clients connect to the winner.
        FileHandle.standardError.write(Data("reticle helper-daemon: \(error)\n".utf8))
        helperClient.shutdown()
        return 0
    }

    installShutdownSignalHandlers { server.stop() }
    FileHandle.standardError.write(
        Data("reticle helper-daemon: listening on \(socketPath) (helper \(helper), idle-exit \(Int(idle))s)\n".utf8))
    server.run()
    helperClient.shutdown()
    return 0
}

/// Keeps signal sources alive for the process lifetime.
private nonisolated(unsafe) var shutdownSignalSources: [DispatchSourceSignal] = []

private func installShutdownSignalHandlers(_ handler: @escaping @Sendable () -> Void) {
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler(handler: handler)
        source.resume()
        shutdownSignalSources.append(source)
    }
}
