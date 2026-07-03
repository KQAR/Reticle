import Foundation

/// Error surfaced by the Kotlin helper or by the JSONL process boundary.
public struct HelperError: Error, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

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

    /// Creates a helper client that applies `serial` to every device RPC call.
    init(launcher: String, javaHome: String?, serial: String? = nil) {
        self.serial = serial
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
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data("\n".utf8))

        guard let line = reader.nextLine() else {
            throw HelperError("helper closed stdout before responding to '\(method)'")
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

    /// Closes stdin so the helper exits its serve loop.
    func shutdown() {
        stdinPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
    }
}

/// Minimal blocking buffered line reader over a file handle.
final class LineReader {
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
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }
}
