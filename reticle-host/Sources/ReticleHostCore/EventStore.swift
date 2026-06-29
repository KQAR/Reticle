import Foundation

/// Append-only session event store backed by `events.jsonl` and a bounded buffer.
public final class EventStore: @unchecked Sendable {
    public typealias Subscriber = (ReticleEventEnvelope) -> Void

    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let limit: Int
    private var buffer: [ReticleEventEnvelope] = []
    private var subscribers: [UUID: Subscriber] = [:]
    private var nextSequence: UInt64 = 1

    public let session: String
    public let sessionDirectory: URL
    public let eventsFile: URL

    /// Creates or opens a session event store.
    public init(session: String, rootDirectory: URL, limit: Int = 500) throws {
        self.session = session
        self.limit = max(1, limit)
        sessionDirectory = rootDirectory.appendingPathComponent(session, isDirectory: true)
        eventsFile = sessionDirectory.appendingPathComponent("events.jsonl")
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: eventsFile.path) {
            _ = FileManager.default.createFile(atPath: eventsFile.path, contents: nil)
        }
        try loadExistingEvents()
    }

    /// Appends and persists an incoming event, assigning daemon-owned id and time.
    @discardableResult
    public func append(_ request: EventPostRequest) throws -> ReticleEventEnvelope {
        let event = ReticleEventEnvelope(
            id: allocateId(),
            ts: currentTimeMillis(),
            session: session,
            target: request.target,
            source: request.source,
            type: request.type,
            payload: request.payload,
            refs: request.refs
        )
        try appendStamped(event)
        return event
    }

    /// Returns buffered events after `since`; nil returns the whole buffer.
    public func events(since: String? = nil) -> [ReticleEventEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        guard let since else { return buffer }
        return buffer.filter { $0.id > since }
    }

    /// Number of events currently retained in memory.
    public var eventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    /// Adds a live event subscriber and returns a token for removing it.
    @discardableResult
    public func subscribe(_ subscriber: @escaping Subscriber) -> UUID {
        let token = UUID()
        lock.lock()
        subscribers[token] = subscriber
        lock.unlock()
        return token
    }

    /// Removes a live event subscriber.
    public func unsubscribe(_ token: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: token)
        lock.unlock()
    }

    private func appendStamped(_ event: ReticleEventEnvelope) throws {
        let line = try encoder.encode(event) + Data("\n".utf8)
        let handle = try FileHandle(forWritingTo: eventsFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.close()

        let callbacks: [Subscriber]
        lock.lock()
        buffer.append(event)
        trimBuffer()
        callbacks = Array(subscribers.values)
        lock.unlock()
        callbacks.forEach { $0(event) }
    }

    private func loadExistingEvents() throws {
        let data = try Data(contentsOf: eventsFile)
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        var loaded: [ReticleEventEnvelope] = []
        var highest: UInt64 = 0
        for line in text.split(separator: "\n") {
            guard let lineData = String(line).data(using: .utf8) else { continue }
            let event = try decoder.decode(ReticleEventEnvelope.self, from: lineData)
            loaded.append(event)
            highest = max(highest, sequence(from: event.id) ?? 0)
        }
        lock.lock()
        buffer = Array(loaded.suffix(limit))
        nextSequence = highest + 1
        lock.unlock()
    }

    private func allocateId() -> String {
        lock.lock()
        defer { lock.unlock() }
        let id = String(format: "evt_%016llu", nextSequence)
        nextSequence += 1
        return id
    }

    private func trimBuffer() {
        if buffer.count > limit {
            buffer.removeFirst(buffer.count - limit)
        }
    }

    private func currentTimeMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func sequence(from id: String) -> UInt64? {
        guard id.hasPrefix("evt_") else { return nil }
        return UInt64(id.dropFirst(4))
    }
}
