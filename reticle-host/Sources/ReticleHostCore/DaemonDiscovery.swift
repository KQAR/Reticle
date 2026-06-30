import Foundation
import Darwin

/// Metadata written by `reticle serve` so one-shot commands can find it.
public struct DaemonInfo: Codable, Equatable {
    public let pid: Int32
    public let port: Int
    public let session: String
    public let startedAt: Int64
}

/// Reads and writes the local daemon discovery file under `~/.reticle`.
public struct DaemonDiscovery {
    public let fileURL: URL

    /// Creates discovery for a custom file or the default `~/.reticle/daemon.json`.
    public init(fileURL: URL = DaemonDiscovery.defaultFileURL()) {
        self.fileURL = fileURL
    }

    /// Default Reticle home directory.
    public static func reticleHome() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".reticle", isDirectory: true)
    }

    /// Default daemon discovery file.
    public static func defaultFileURL() -> URL {
        reticleHome().appendingPathComponent("daemon.json")
    }

    /// Writes a discovery file for the running daemon.
    public func write(_ info: DaemonInfo) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(info)
        try data.write(to: fileURL, options: [.atomic])
    }

    /// Reads live daemon metadata; stale pids are ignored.
    public func readLive() -> DaemonInfo? {
        guard
            let data = try? Data(contentsOf: fileURL),
            let info = try? JSONDecoder().decode(DaemonInfo.self, from: data),
            isProcessAlive(info.pid)
        else {
            return nil
        }
        return info
    }

    /// Trace artifact directory for a daemon-owned session.
    public func traceDirectory(for info: DaemonInfo) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(info.session, isDirectory: true)
            .appendingPathComponent("traces", isDirectory: true)
    }

    /// Removes the discovery file if it still points at `pid`.
    public func clearIfOwned(by pid: Int32) {
        guard let info = readLive(), info.pid == pid else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func isProcessAlive(_ pid: Int32) -> Bool {
        pid > 0 && kill(pid, 0) == 0
    }
}

/// Best-effort publisher used by one-shot CLI commands.
public struct DaemonEventPublisher {
    private let discovery: DaemonDiscovery
    private let timeout: TimeInterval

    /// Creates a publisher against the default daemon discovery file.
    public init(discovery: DaemonDiscovery = DaemonDiscovery(), timeout: TimeInterval = 1.0) {
        self.discovery = discovery
        self.timeout = timeout
    }

    /// Publishes an action trace file to the running daemon if one is discoverable.
    public func publishActionTrace(path: String) -> Result<Void, Error> {
        guard let info = discovery.readLive() else { return .success(()) }
        guard let url = URL(string: "http://127.0.0.1:\(info.port)/sessions/current/action-traces") else {
            return .failure(HelperError("invalid daemon URL"))
        }
        let body = ["path": path]
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            return post(url: url, data: data)
        } catch {
            return .failure(error)
        }
    }

    private func post(url: URL, data: Data) -> Result<Void, Error> {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let sema = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            defer { sema.signal() }
            if let error {
                box.set(.failure(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !(200..<300).contains(status) {
                box.set(.failure(HelperError("daemon rejected event with HTTP \(status)")))
            }
        }
        task.resume()
        if sema.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return .failure(HelperError("daemon event publish timed out"))
        }
        return box.value
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error> = .success(())

    var value: Result<Void, Error> {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func set(_ value: Result<Void, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }
}
