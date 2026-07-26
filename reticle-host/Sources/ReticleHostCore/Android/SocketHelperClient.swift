import Darwin
import Foundation

/// Locations and naming for the per-device resident helper daemon.
enum Helperd {
    static let defaultIdleSeconds: TimeInterval = 600
    static let spawnWaitSeconds: TimeInterval = 5

    static func rootDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".reticle/helperd", isDirectory: true)
    }

    /// One daemon per device: keyed by the explicit serial (or $ANDROID_SERIAL),
    /// falling back to a shared "default" daemon when no device is pinned — the
    /// helper resolves the device per call exactly as a direct spawn would.
    static func socketPath(serial: String?) -> String {
        let raw = serial ?? ProcessInfo.processInfo.environment["ANDROID_SERIAL"] ?? "default"
        return rootDirectory().appendingPathComponent("\(fileKey(raw)).sock").path
    }

    static func logPath(socketPath: String) -> String {
        (socketPath as NSString).deletingPathExtension + ".log"
    }

    /// Sanitized, collision-safe file key for a device serial. Serials can
    /// carry ':' and other non-filename characters (`ip:port` transport
    /// serials); when sanitizing changes the string, an FNV-1a suffix keeps
    /// distinct serials from mapping to the same socket.
    static func fileKey(_ raw: String) -> String {
        let sanitized = String(raw.map { c -> Character in
            (c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_" || c == ".")) ? c : "-"
        })
        let clipped = String(sanitized.prefix(40))
        if clipped == raw { return clipped }
        var hash: UInt64 = 0xcbf29ce484222325
        for b in raw.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        return "\(clipped)-\(String(String(hash, radix: 16).prefix(8)))"
    }
}

/// Minimal POSIX Unix-domain stream socket helpers.
enum UnixSocket {
    static func makeAddress(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8CString) // includes the trailing NUL
        guard bytes.count <= capacity else {
            throw HelperError("unix socket path too long (\(path.utf8.count) bytes): \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            bytes.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[0..<bytes.count]))
            }
        }
        return addr
    }

    /// Connects to a listening socket; nil when absent/refused (the caller
    /// decides whether that means "spawn the daemon" or "stale socket file").
    static func connect(_ path: String) -> Int32? {
        guard var addr = try? makeAddress(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            close(fd)
            return nil
        }
        return fd
    }

    /// Writes the whole buffer, retrying partial writes; false on error (the
    /// peer vanished — SIGPIPE is ignored process-wide, so this is an errno).
    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += n
            }
            return true
        }
    }
}

/// Buffered newline-delimited reader over a raw fd (the socket analogue of
/// `LineReader` over a `FileHandle`).
final class FdLineReader: @unchecked Sendable {
    enum Outcome {
        case line(String)
        case eof
        case timedOut
    }

    private let fd: Int32
    private var buffer = Data()

    init(fd: Int32) {
        self.fd = fd
    }

    /// Reads the next line. `.timedOut` surfaces an `SO_RCVTIMEO` expiry when
    /// the caller armed one; without it reads block indefinitely.
    func nextLine() -> Outcome {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                return .line(String(data: lineData, encoding: .utf8) ?? "")
            }
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                continue
            }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return .timedOut }
            }
            // EOF: surface a final unterminated line rather than dropping it.
            guard !buffer.isEmpty else { return .eof }
            defer { buffer.removeAll() }
            return .line(String(data: buffer, encoding: .utf8) ?? "")
        }
    }
}

/// Helper RPC over the resident daemon's Unix socket. The wire format is the
/// helper's own JSONL envelope — the daemon forwards frames to its long-lived
/// helper child verbatim, plus the `helperd/*` control methods it answers
/// itself.
final class SocketHelperClient: HelperCalling, @unchecked Sendable {
    private let socketPath: String
    private let serial: String?
    private let callLock = NSLock()
    private let fd: Int32
    private let reader: FdLineReader
    private var nextId = 1

    /// Connects or returns nil when nothing listens on `socketPath`.
    /// `callTimeout` must exceed the daemon-side helper RPC timeout (60s) so
    /// the daemon's specific error surfaces before this generic one.
    init?(socketPath: String, serial: String?, callTimeout: TimeInterval = 70) {
        guard let fd = UnixSocket.connect(socketPath) else { return nil }
        var tv = timeval(tv_sec: Int(callTimeout), tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        self.socketPath = socketPath
        self.serial = serial
        self.fd = fd
        self.reader = FdLineReader(fd: fd)
    }

    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        callLock.lock()
        defer { callLock.unlock() }

        let id = nextId
        nextId += 1

        var params = params
        if let serial, params["serial"] == nil {
            params["serial"] = serial
        }

        let request: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: request)
        guard UnixSocket.writeAll(fd, data + Data("\n".utf8)) else {
            throw HelperError("failed to send '\(method)' to the helper daemon (daemon exited?)")
        }

        let line: String
        switch reader.nextLine() {
        case .line(let l):
            line = l
        case .eof:
            throw HelperError("helper daemon closed the connection before responding to '\(method)'")
        case .timedOut:
            throw HelperError("helper daemon timed out responding to '\(method)'")
        }
        guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw HelperError("non-object response from helper daemon: \(line)")
        }
        if let respId = obj["id"] as? Int, respId != id {
            throw HelperError("daemon response id \(respId) did not match request id \(id)")
        }
        if (obj["ok"] as? Bool) == true {
            return (obj["result"] as? [String: Any]) ?? [:]
        }
        throw HelperError(obj["error"] as? String ?? "<no error message>")
    }

    func close() {
        Darwin.close(fd)
    }
}

/// Brings up the hot path: connect to the per-device daemon socket, spawning
/// the daemon on first use and restarting it when stale. Every failure returns
/// nil so the caller falls back to today's direct helper spawn — the hot path
/// must never be a reliability regression.
enum HelperDaemonLauncher {
    static func disabled(_ args: Args) -> Bool {
        args.option("no-daemon") == "true"
            || ProcessInfo.processInfo.environment["RETICLE_NO_DAEMON"] == "1"
    }

    static func ensureClient(args: Args, serial: String?) -> SocketHelperClient? {
        guard !disabled(args) else { return nil }
        // No helper resolvable: let the direct path report its own error.
        guard let helper = resolveHelper(args) else { return nil }
        let socketPath = Helperd.socketPath(serial: serial)
        do {
            return try connectFresh(socketPath: socketPath, helper: helper, serial: serial)
        } catch {
            FileHandle.standardError.write(
                Data("note: helper daemon unavailable (\(error)); running without it\n".utf8))
            return nil
        }
    }

    private static func connectFresh(socketPath: String, helper: String, serial: String?) throws -> SocketHelperClient {
        let client = try connectOrSpawn(socketPath: socketPath, helper: helper, serial: serial)
        // Stale-daemon guard: a resident daemon left by an older CLI, or one
        // whose helper binary has since been rebuilt, must not serve this call
        // with yesterday's behavior. Ask it to exit and bring up a fresh one.
        if isStale(client: client, helper: helper) {
            _ = try? client.call("helperd/shutdown")
            client.close()
            waitForSocketGone(socketPath, deadline: 2)
            return try connectOrSpawn(socketPath: socketPath, helper: helper, serial: serial)
        }
        return client
    }

    private static func isStale(client: SocketHelperClient, helper: String) -> Bool {
        guard let info = try? client.call("helperd/info") else { return true }
        return info["version"] as? String != ReticleCLI.version
            || info["helperPath"] as? String != helper
            || info["helperMtime"] as? Int != helperMtime(helper)
    }

    static func helperMtime(_ path: String) -> Int {
        let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return Int(date?.timeIntervalSince1970 ?? 0)
    }

    private static func connectOrSpawn(socketPath: String, helper: String, serial: String?) throws -> SocketHelperClient {
        if let client = SocketHelperClient(socketPath: socketPath, serial: serial) {
            return client
        }
        try spawnDaemon(socketPath: socketPath, helper: helper)
        let deadline = Date().addingTimeInterval(Helperd.spawnWaitSeconds)
        while Date() < deadline {
            if let client = SocketHelperClient(socketPath: socketPath, serial: serial) {
                return client
            }
            usleep(100_000)
        }
        throw HelperError("helper daemon socket did not come up within \(Int(Helperd.spawnWaitSeconds))s at \(socketPath) — see \(Helperd.logPath(socketPath: socketPath))")
    }

    private static func spawnDaemon(socketPath: String, helper: String) throws {
        try FileManager.default.createDirectory(at: Helperd.rootDirectory(), withIntermediateDirectories: true)
        let logPath = Helperd.logPath(socketPath: socketPath)
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        let log = FileHandle(forWritingAtPath: logPath)
        log?.seekToEndOfFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: selfExecutablePath())
        process.arguments = ["helper-daemon", "--socket", socketPath, "--helper", helper]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log ?? FileHandle.nullDevice
        process.standardError = log ?? FileHandle.nullDevice
        try process.run()
        // Deliberately not waited on: the daemon detaches itself (setsid) and
        // outlives this one-shot command. When two commands race to spawn, the
        // bind loser exits on its own and both connect to the winner.
    }

    private static func selfExecutablePath() -> String {
        if let exe = Bundle.main.executablePath { return exe }
        let argv0 = CommandLine.arguments[0]
        if argv0.contains("/") {
            return URL(fileURLWithPath: argv0,
                       relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).path
        }
        return argv0
    }

    private static func waitForSocketGone(_ path: String, deadline seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && FileManager.default.fileExists(atPath: path) {
            usleep(50_000)
        }
    }
}
