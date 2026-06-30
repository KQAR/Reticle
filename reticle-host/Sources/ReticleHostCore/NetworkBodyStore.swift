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
    private let limitBytes: Int
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
}
