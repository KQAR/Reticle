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
    /// Canonical directory paths artifacts may be served from. Seeded with the
    /// sessions root (where in-process producers — network bodies, screenshots —
    /// write). Trusted ingest paths widen it via `registerArtifactRoot`.
    private var allowedArtifactRoots: Set<String> = []

    public let session: String
    public let rootDirectory: URL
    public let sessionDirectory: URL
    public let eventsFile: URL

    /// Creates or opens a session event store.
    public init(session: String, rootDirectory: URL, limit: Int = 500) throws {
        self.session = session
        self.rootDirectory = rootDirectory
        self.limit = max(1, limit)
        sessionDirectory = rootDirectory.appendingPathComponent(session, isDirectory: true)
        eventsFile = sessionDirectory.appendingPathComponent("events.jsonl")
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: eventsFile.path) {
            _ = FileManager.default.createFile(atPath: eventsFile.path, contents: nil)
        }
        allowedArtifactRoots = [Self.canonicalPath(rootDirectory)]
        try loadExistingEvents()
    }

    /// Marks [directory] as a trusted root artifacts may be served from. Called
    /// when the daemon ingests a trace whose evidence lives outside the sessions
    /// root (e.g. a user-chosen `--trace-output`).
    public func registerArtifactRoot(_ directory: URL) {
        let canonical = Self.canonicalPath(directory)
        lock.lock()
        allowedArtifactRoots.insert(canonical)
        lock.unlock()
    }

    /// Whether [fileURL] resolves to a file inside one of the allowed artifact
    /// roots. Symlinks and `..` are resolved first so a stored ref cannot escape
    /// the allowlist to read arbitrary files (e.g. an event POSTed by a local
    /// process pointing at `/etc/passwd`).
    public func isArtifactPathAllowed(_ fileURL: URL) -> Bool {
        let target = Self.canonicalComponents(fileURL)
        lock.lock()
        let roots = allowedArtifactRoots
        lock.unlock()
        for root in roots {
            let rootComponents = root.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard target.count > rootComponents.count else { continue }
            if Array(target.prefix(rootComponents.count)) == rootComponents {
                return true
            }
        }
        return false
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func canonicalPath(_ url: URL) -> String {
        canonicalURL(url).path
    }

    private static func canonicalComponents(_ url: URL) -> [String] {
        canonicalURL(url).pathComponents.filter { $0 != "/" }
    }

    /// Appends and persists an incoming event, assigning daemon-owned id and time.
    @discardableResult
    public func append(_ request: EventPostRequest) throws -> ReticleEventEnvelope {
        lock.lock()
        let event: ReticleEventEnvelope
        let callbacks: [Subscriber]
        do {
            event = ReticleEventEnvelope(
                id: allocateIdLocked(),
                ts: currentTimeMillis(),
                session: session,
                target: request.target,
                source: request.source,
                type: request.type,
                payload: request.payload,
                refs: request.refs
            )
            callbacks = try appendStampedLocked(event)
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        callbacks.forEach { $0(event) }
        return event
    }

    /// Returns buffered events after `since`; nil returns the whole buffer.
    public func events(since: String? = nil) -> [ReticleEventEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        guard let since else { return buffer }
        return buffer.filter { $0.id > since }
    }

    /// Returns one buffered event by daemon-assigned id.
    public func event(id: String) -> ReticleEventEnvelope? {
        lock.lock()
        defer { lock.unlock() }
        return buffer.first { $0.id == id }
    }

    /// Number of events currently retained in memory.
    public var eventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    /// Lists all persisted sessions under the same sessions root.
    public func sessionInfos() throws -> [SessionInfo] {
        try Self.sessionInfos(rootDirectory: rootDirectory, currentSession: session)
    }

    /// Loads persisted events for a session id without subscribing to live changes.
    public func historicalEvents(session id: String, since: String? = nil) throws -> [ReticleEventEnvelope] {
        if id == session {
            return events(since: since)
        }
        let events = try Self.loadEvents(session: id, rootDirectory: rootDirectory)
        guard let since else { return events }
        return events.filter { $0.id > since }
    }

    /// Finds a persisted event by id in either the current or a historical session.
    public func historicalEvent(session id: String, eventId: String) throws -> ReticleEventEnvelope? {
        if id == session {
            return event(id: eventId)
        }
        return try Self.loadEvents(session: id, rootDirectory: rootDirectory).first { $0.id == eventId }
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

    private func appendStampedLocked(_ event: ReticleEventEnvelope) throws -> [Subscriber] {
        let line = try encoder.encode(event) + Data("\n".utf8)
        let handle = try FileHandle(forWritingTo: eventsFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.close()

        buffer.append(event)
        trimBuffer()
        return Array(subscribers.values)
    }

    private func loadExistingEvents() throws {
        let data = try Data(contentsOf: eventsFile)
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
        var loaded: [ReticleEventEnvelope] = []
        var highest: UInt64 = 0
        // Tolerate a corrupt or partially-written line rather than failing the
        // whole session: an append is not atomic and not fsync'd, so a crash
        // mid-write can leave a truncated trailing line (or a torn one). Skip
        // what won't decode and keep the rest — one bad line must not make
        // `reticle serve` unable to start on an otherwise valid session.
        for line in text.split(separator: "\n") {
            guard let lineData = String(line).data(using: .utf8),
                  let event = try? decoder.decode(ReticleEventEnvelope.self, from: lineData) else {
                continue
            }
            loaded.append(event)
            highest = max(highest, sequence(from: event.id) ?? 0)
        }
        lock.lock()
        buffer = Array(loaded.suffix(limit))
        nextSequence = highest + 1
        lock.unlock()
    }

    private func allocateIdLocked() -> String {
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

    private static func sessionInfos(rootDirectory: URL, currentSession: String) throws -> [SessionInfo] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let infos = try urls.compactMap { url -> SessionInfo? in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values.isDirectory == true else { return nil }
            let id = url.lastPathComponent
            guard isSafeSessionID(id) else { return nil }
            let events = try loadEvents(session: id, rootDirectory: rootDirectory)
            let eventsFile = eventsFile(session: id, rootDirectory: rootDirectory)
            let updatedAt = modificationMillis(for: eventsFile) ?? values.contentModificationDate.map(millis)
            return SessionInfo(
                id: id,
                path: url.path,
                eventCount: events.count,
                actionTraceCount: events.filter { $0.type == "action.trace" }.count,
                updatedAtMillis: updatedAt,
                isCurrent: id == currentSession
            )
        }
        return infos.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            return ($0.updatedAtMillis ?? 0) > ($1.updatedAtMillis ?? 0)
        }
    }

    private static func loadEvents(session id: String, rootDirectory: URL) throws -> [ReticleEventEnvelope] {
        guard isSafeSessionID(id) else {
            throw EventStoreError.invalidSession(id)
        }
        let file = eventsFile(session: id, rootDirectory: rootDirectory)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw EventStoreError.sessionNotFound(id)
        }
        let data = try Data(contentsOf: file)
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        // Skip corrupt/partial lines (see loadExistingEvents) instead of throwing,
        // so listing sessions and reading history never fail on one torn line.
        return text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(ReticleEventEnvelope.self, from: data)
        }
    }

    private static func eventsFile(session id: String, rootDirectory: URL) -> URL {
        rootDirectory
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("events.jsonl")
    }

    private static func isSafeSessionID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.contains("/")
    }

    private static func modificationMillis(for url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap(\.contentModificationDate)
            .map(millis)
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }
}
