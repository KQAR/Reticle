import Foundation

/// Stores captured network bodies as session artifacts instead of inline event JSON.
final class NetworkBodyStore: @unchecked Sendable {
    struct StoredBody {
        let refName: String
        let path: String
        let bytes: Int
        let truncated: Bool
    }

    private let directory: URL
    let limitBytes: Int
    private let lock = NSLock()

    /// Creates a body store below the current session directory.
    init(sessionDirectory: URL, limitBytes: Int = 1024 * 1024) {
        directory = sessionDirectory.appendingPathComponent("network-bodies", isDirectory: true)
        self.limitBytes = max(0, limitBytes)
    }

    /// Writes a request or response body artifact and returns its event ref.
    func store(_ data: Data, requestId: String, role: String) throws -> StoredBody? {
        guard !data.isEmpty else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeRole = role == "response" ? "responseBody" : "requestBody"
        let refName = "\(safeRole).\(requestId)"
        let url = directory.appendingPathComponent("\(requestId)-\(safeRole).bin")
        let slice = data.prefix(limitBytes)
        lock.lock()
        defer { lock.unlock() }
        try Data(slice).write(to: url, options: .atomic)
        return StoredBody(
            refName: refName,
            path: url.path,
            bytes: data.count,
            truncated: data.count > slice.count
        )
    }

    /// Writes an already-bounded body prefix for a streamed transfer and reports
    /// the full transfer size. The streaming path caps `prefix` at `limitBytes`
    /// while it forwards every byte to the client, so `bytes` is the true total
    /// and `truncated` reflects whether the stored artifact is shorter than it.
    func store(prefix: Data, totalBytes: Int, requestId: String, role: String) throws -> StoredBody? {
        guard totalBytes > 0 else { return nil }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeRole = role == "response" ? "responseBody" : "requestBody"
        let refName = "\(safeRole).\(requestId)"
        let url = directory.appendingPathComponent("\(requestId)-\(safeRole).bin")
        let capped = prefix.prefix(limitBytes)
        lock.lock()
        defer { lock.unlock() }
        try Data(capped).write(to: url, options: .atomic)
        return StoredBody(
            refName: refName,
            path: url.path,
            bytes: totalBytes,
            truncated: totalBytes > capped.count
        )
    }
}
