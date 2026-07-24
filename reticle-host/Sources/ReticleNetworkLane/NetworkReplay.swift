import Foundation

/// Overrides applied to a captured flow before re-sending it. This is the wire DTO
/// the CLI posts to the daemon; the lane translates it into Loom's `ReplayOverrides`.
/// `body` / `bodyBase64` / `clearBody` are mutually exclusive — omit all three to
/// keep the source flow's body.
public struct NetworkReplayRequest: Codable {
    public var method: String?
    public var url: String?
    /// Header name → value to add or overwrite (matched case-insensitively).
    public var setHeaders: [String: String]?
    /// Header names to remove (matched case-insensitively).
    public var removeHeaders: [String]?
    /// UTF-8 replacement request body.
    public var body: String?
    /// Base64 replacement request body, for binary payloads.
    public var bodyBase64: String?
    /// Send an empty request body.
    public var clearBody: Bool?

    public init(
        method: String? = nil,
        url: String? = nil,
        setHeaders: [String: String]? = nil,
        removeHeaders: [String]? = nil,
        body: String? = nil,
        bodyBase64: String? = nil,
        clearBody: Bool? = nil
    ) {
        self.method = method
        self.url = url
        self.setHeaders = setHeaders
        self.removeHeaders = removeHeaders
        self.body = body
        self.bodyBase64 = bodyBase64
        self.clearBody = clearBody
    }

    /// Validates the mutually-exclusive body inputs and returns the replacement
    /// bytes intent: nil = keep, .some(nil) = clear, .some(data) = replace.
    public func resolvedBody() throws -> Data?? {
        let bodyInputs = [body != nil, bodyBase64 != nil, clearBody == true].filter { $0 }.count
        if bodyInputs > 1 {
            throw NetworkReplayError.invalid("body, bodyBase64, and clearBody are mutually exclusive")
        }
        if clearBody == true { return .some(nil) }
        if let body { return .some(Data(body.utf8)) }
        if let bodyBase64 {
            guard let data = Data(base64Encoded: bodyBase64) else {
                throw NetworkReplayError.invalid("bodyBase64 is not valid base64")
            }
            return .some(data)
        }
        return nil
    }

    /// A short, display-safe summary of what was overridden (no header values).
    public var summary: [String] {
        var parts: [String] = []
        if let method { parts.append("method=\(method)") }
        if let url { parts.append("url=\(url)") }
        for name in (removeHeaders ?? []) { parts.append("-\(name)") }
        for name in (setHeaders ?? [:]).keys.sorted() { parts.append("+\(name)") }
        if clearBody == true { parts.append("body=cleared") }
        else if body != nil || bodyBase64 != nil { parts.append("body=replaced") }
        return parts
    }
}

/// The difference between the original captured response and the replayed one. The
/// header lists carry names only — never values — so a replay diff can name a
/// sensitive header changing (`Authorization`) without logging the secret.
public struct NetworkReplayDiff: Codable, Equatable {
    public var statusFrom: Int?
    public var statusTo: Int?
    public var statusChanged: Bool
    public var bodyBytesFrom: Int
    public var bodyBytesTo: Int
    public var bodyChanged: Bool
    public var headersAdded: [String]
    public var headersRemoved: [String]
    public var headersChanged: [String]

    /// Pure comparator over response primitives, so the diff logic is testable
    /// without a live proxy. Header comparison is case-insensitive by name.
    public static func between(
        sourceStatus: Int?,
        sourceHeaders: [String: String],
        sourceBody: Data?,
        replayStatus: Int?,
        replayHeaders: [String: String],
        replayBody: Data?
    ) -> NetworkReplayDiff {
        let source = normalize(sourceHeaders)
        let replay = normalize(replayHeaders)
        let sourceNames = Set(source.keys)
        let replayNames = Set(replay.keys)
        let added = replayNames.subtracting(sourceNames)
        let removed = sourceNames.subtracting(replayNames)
        let changed = sourceNames.intersection(replayNames).filter { source[$0] != replay[$0] }
        let sourceBytes = sourceBody?.count ?? 0
        let replayBytes = replayBody?.count ?? 0
        return NetworkReplayDiff(
            statusFrom: sourceStatus,
            statusTo: replayStatus,
            statusChanged: sourceStatus != replayStatus,
            bodyBytesFrom: sourceBytes,
            bodyBytesTo: replayBytes,
            bodyChanged: (sourceBody ?? Data()) != (replayBody ?? Data()),
            headersAdded: added.sorted(),
            headersRemoved: removed.sorted(),
            headersChanged: changed.sorted()
        )
    }

    /// True when the replayed response is byte-for-byte identical to the original.
    public var isIdentical: Bool {
        !statusChanged && !bodyChanged && headersAdded.isEmpty && headersRemoved.isEmpty && headersChanged.isEmpty
    }

    private static func normalize(_ headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in headers { result[name.lowercased()] = value }
        return result
    }
}

/// The outcome of a replay, returned to the CLI and mirrored into the emitted
/// `network.replay` event.
public struct NetworkReplayResult: Codable, Equatable {
    /// The new (replayed) flow id.
    public var requestId: String
    /// The source flow this was replayed from.
    public var replayedFrom: String
    public var status: Int?
    public var error: String?
    public var diff: NetworkReplayDiff

    public init(requestId: String, replayedFrom: String, status: Int?, error: String?, diff: NetworkReplayDiff) {
        self.requestId = requestId
        self.replayedFrom = replayedFrom
        self.status = status
        self.error = error
        self.diff = diff
    }
}

/// The capability the daemon route needs — replay a captured flow by id with
/// overrides. `LoomCaptureLane` provides it; the HTTP server holds it late-bound
/// because the lane is created after the server starts.
public protocol FlowReplaying: AnyObject, Sendable {
    func replay(requestId: String, request: NetworkReplayRequest) throws -> NetworkReplayResult
}

public enum NetworkReplayError: Error, CustomStringConvertible {
    case invalid(String)
    case notFound(String)
    case failed(String)

    public var description: String {
        switch self {
        case .invalid(let m), .notFound(let m), .failed(let m): return m
        }
    }
}
