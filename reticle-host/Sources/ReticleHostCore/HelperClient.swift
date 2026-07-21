import Foundation

/// Minimal call surface shared by local helper processes and daemon-forwarded RPC.
public protocol HelperCalling: AnyObject, Sendable {
    @discardableResult
    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any]
}

public extension HelperCalling {
    @discardableResult
    func call(_ method: String) throws -> [String: Any] {
        try call(method, [:])
    }
}

/// A long-lived client over the Kotlin helper's JSONL stdio RPC.
final class HelperClient: HelperCalling, @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let callLock = NSLock()
    private var reader: LineReader!
    private var nextId = 1
    private let serial: String?
    private let callTimeout: TimeInterval

    /// Creates a helper client that applies `serial` to every device RPC call.
    /// `callTimeout` bounds how long a single RPC waits for the helper's reply
    /// before the helper is declared wedged (default 60s — generous enough for
    /// the slowest legitimate op, JDWP inject ~20s + awaitRuntime ~10s, so it
    /// only trips on a genuine hang).
    init(launcher: String, javaHome: String?, serial: String? = nil, callTimeout: TimeInterval = 60) {
        self.serial = serial
        self.callTimeout = callTimeout
        process.executableURL = URL(fileURLWithPath: launcher)
        process.arguments = ["helper"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError
        if let javaHome {
            var env = ProcessInfo.processInfo.environment
            env["JAVA_HOME"] = javaHome
            process.environment = env
        }
    }

    /// Starts the helper process and prepares the line reader.
    func start() throws {
        try process.run()
        reader = LineReader(handle: stdoutPipe.fileHandleForReading)
    }

    /// Sends one request and returns the successful `result` object.
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
        // The throwing write surfaces EPIPE as a HelperError; the legacy
        // write(_:) raises an uncatchable ObjC exception when the helper died.
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data + Data("\n".utf8))
        } catch {
            throw HelperError("failed to send '\(method)' to helper (process exited?): \(error.localizedDescription)")
        }

        let line: String
        switch readLine(timeout: callTimeout) {
        case .line(let l):
            line = l
        case .eof:
            throw HelperError("helper closed stdout before responding to '\(method)'")
        case .timedOut:
            // The helper is wedged (adb stuck past its own timeout, JDWP hang,
            // …). Terminate it so this call fails fast and every later call
            // errors on a dead process, rather than blocking forever under
            // callLock and wedging the whole host.
            process.terminate()
            throw HelperError("helper timed out after \(Int(callTimeout))s responding to '\(method)' (helper terminated)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw HelperError("non-object response: \(line)")
        }
        if let respId = obj["id"] as? Int, respId != id {
            throw HelperError("response id \(respId) did not match request id \(id)")
        }
        if (obj["ok"] as? Bool) == true {
            return (obj["result"] as? [String: Any]) ?? [:]
        }
        throw HelperError(obj["error"] as? String ?? "<no error message>")
    }

    private enum ReadOutcome {
        case line(String)
        case eof
        case timedOut
    }

    /// Reads one reply line with a deadline. The underlying `availableData` read
    /// is blocking and cannot itself be cancelled, so it runs on a background
    /// queue; on timeout we return `.timedOut` and the caller terminates the
    /// helper, which sends EOF and lets the orphaned read finish harmlessly.
    private func readLine(timeout: TimeInterval) -> ReadOutcome {
        let sem = DispatchSemaphore(value: 0)
        // .success(line?) — nil line means EOF. Safe to capture: readLine only
        // runs under callLock, so there is exactly one reader at a time.
        let box = ResultBox<String?>(fallback: .success(nil))
        DispatchQueue.global().async { [reader] in
            box.set(.success(reader?.nextLine() ?? nil))
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            return .timedOut
        }
        if case let .success(line?) = box.value { return .line(line) }
        return .eof
    }

    /// Closes stdin so the helper exits its serve loop.
    func shutdown() {
        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}

/// Minimal blocking buffered line reader over a file handle. `@unchecked
/// Sendable` because `HelperClient` only ever touches it under `callLock`, so the
/// background read in `readLine(timeout:)` is never concurrent with another read.
final class LineReader: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func nextLine() -> String? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                return String(data: lineData, encoding: .utf8)
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                // EOF: hand back a final unterminated line rather than dropping
                // it — a helper that crashes mid-reply still gets its last
                // (possibly diagnostic) output surfaced instead of swallowed.
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return String(data: buffer, encoding: .utf8)
            }
            buffer.append(chunk)
        }
    }
}
