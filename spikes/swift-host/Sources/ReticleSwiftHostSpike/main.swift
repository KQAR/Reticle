import Foundation

// Spike goal: prove a Swift host can drive the Kotlin reticle-android-helper as a
// long-lived child process over newline-delimited JSON on stdin/stdout. This is
// the single highest-risk part of the "Swift host + Kotlin Android helper"
// direction — if this boundary is reliable, the rest is mechanical.
//
// Usage:
//   swift run ReticleSwiftHostSpike <path-to-reticle-cli-launcher>
// e.g.
//   swift run ReticleSwiftHostSpike ../../reticle-cli/build/install/reticle/bin/reticle

/// A long-lived client over the helper's JSONL stdio RPC. One spawn, many calls —
/// matching the roadmap rule that the helper is a resident service, not
/// fork-per-call.
final class HelperClient {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private var reader: LineReader!
    private var nextId = 1

    init(launcher: String, javaHome: String?) {
        process.executableURL = URL(fileURLWithPath: launcher)
        process.arguments = ["helper"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // Helper diagnostics go to stderr; let them flow to ours so we can see them.
        process.standardError = FileHandle.standardError
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

    /// Send one request, block for its single-line response, parse the envelope.
    func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let id = nextId; nextId += 1
        let request: [String: Any] = ["id": id, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: request)
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data("\n".utf8))

        guard let line = reader.nextLine() else {
            throw SpikeError("helper closed stdout before responding to '\(method)'")
        }
        guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw SpikeError("non-object response: \(line)")
        }
        if (obj["ok"] as? Bool) == true {
            return (obj["result"] as? [String: Any]) ?? [:]
        } else {
            throw SpikeError("helper error: \(obj["error"] as? String ?? "<none>")")
        }
    }

    func shutdown() {
        stdinPipe.fileHandleForWriting.closeFile()  // EOF -> helper exits its loop
        process.waitUntilExit()
    }
}

/// Minimal buffered line reader over a FileHandle (blocking).
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

struct SpikeError: Error, CustomStringConvertible {
    let message: String
    init(_ m: String) { message = m }
    var description: String { message }
}

// --- run ---------------------------------------------------------------------

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: ReticleSwiftHostSpike <path-to-reticle-launcher>\n".utf8))
    exit(2)
}
let launcher = args[1]
let javaHome = ProcessInfo.processInfo.environment["JAVA_HOME"]

let client = HelperClient(launcher: launcher, javaHome: javaHome)
do {
    try client.start()
    print("spike: spawned helper, sending requests over JSONL stdio…\n")

    let pong = try client.call("ping")
    print("✓ ping        -> \(pong)")

    let devices = try client.call("listDevices")
    print("✓ listDevices -> \(devices)")

    // Negative check: an unknown method must come back as a structured error,
    // not crash the helper or wedge the pipe.
    do {
        _ = try client.call("bogusMethod")
        print("✗ expected an error for bogusMethod, got success")
    } catch let e as SpikeError {
        print("✓ bogusMethod -> structured error: \(e.message)")
    }

    // Prove the helper is still alive after the error (the resident-service rule).
    let pong2 = try client.call("ping")
    print("✓ ping again  -> \(pong2)  (helper survived the bad call)")

    client.shutdown()
    print("\nspike: PASS — Swift host drove the Kotlin helper across the RPC boundary.")
} catch {
    FileHandle.standardError.write(Data("spike: FAIL — \(error)\n".utf8))
    client.shutdown()
    exit(1)
}
