import Foundation

/// Error surfaced by the Kotlin helper (an `ok:false` response) or by the
/// boundary itself (process died, unparseable line).
struct HelperError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}

/// A long-lived client over the Kotlin helper's JSONL stdio RPC
/// (reticle-protocol/helper-rpc.md). One spawn, many calls — matching the
/// resident-service rule (the helper is not fork-per-call).
final class HelperClient {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var reader: LineReader!
    private var nextId = 1

    /// - launcher: path to the `reticle` launcher (it runs `reticle helper`).
    /// - javaHome: optional JAVA_HOME to hand the JVM helper.
    init(launcher: String, javaHome: String?) {
        process.executableURL = URL(fileURLWithPath: launcher)
        process.arguments = ["helper"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError  // helper diagnostics flow through
        if let javaHome {
            var env = ProcessInfo.processInfo.environment
            env["JAVA_HOME"] = javaHome
            process.environment = env
        }
    }

    func start() throws {
        try process.run()
        reader = LineReader(handle: stdoutPipe.fileHandleForReading)
    }

    /// Send one request, block for its single-line response, return `result`.
    /// Throws `HelperError` on an `ok:false` response or a broken boundary.
    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let id = nextId; nextId += 1
        let request: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: request)
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data("\n".utf8))

        guard let line = reader.nextLine() else {
            throw HelperError("helper closed stdout before responding to '\(method)'")
        }
        guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw HelperError("non-object response: \(line)")
        }
        // Correlate by id; the helper echoes the request id.
        if let respId = obj["id"] as? Int, respId != id {
            throw HelperError("response id \(respId) did not match request id \(id)")
        }
        if (obj["ok"] as? Bool) == true {
            return (obj["result"] as? [String: Any]) ?? [:]
        }
        throw HelperError(obj["error"] as? String ?? "<no error message>")
    }

    func shutdown() {
        stdinPipe.fileHandleForWriting.closeFile()  // EOF -> helper exits its loop
        process.waitUntilExit()
    }
}

/// Minimal blocking buffered line reader over a FileHandle.
final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()
    init(handle: FileHandle) { self.handle = handle }

    func nextLine() -> String? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                return String(data: lineData, encoding: .utf8)
            }
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }  // EOF
            buffer.append(chunk)
        }
    }
}
