import Foundation
import Synchronization

/// Append-only session event store backed by `events.jsonl` and a bounded buffer.
public final class EventStore: Sendable {
    /// `@Sendable`: a subscriber is registered by one thread (an SSE route) and
    /// invoked by whichever thread appends, so it always crosses threads.
    public typealias Subscriber = @Sendable (ReticleEventEnvelope) -> Void

    /// Everything the readers contend on, in one mutex — so "which lock covers
    /// this field" is not a question the code can get wrong.
    private struct Live {
        var buffer: [ReticleEventEnvelope] = []
        var subscribers: [UUID: Subscriber] = [:]
        var nextSequence: UInt64 = 1
        /// Canonical directory paths artifacts may be served from. Seeded with the
        /// sessions root (where in-process producers — network bodies, screenshots —
        /// write). Trusted ingest paths widen it via `registerArtifactRoot`.
        var allowedArtifactRoots: Set<String> = []
    }
    private let live = Mutex(Live())

    /// The append handle, separate on purpose: encoding + disk I/O must never
    /// hold `live` (which every reader — GET /events, SSE replay — contends on).
    /// Opened once and kept at end-of-file, so each append is one write instead
    /// of open+seek+write+close.
    private let writeHandle: Mutex<FileHandle?> = Mutex(nil)

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let limit: Int

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
        live.withLock { $0.allowedArtifactRoots = [Self.canonicalPath(rootDirectory)] }
        try loadExistingEvents()
    }

    /// Marks [directory] as a trusted root artifacts may be served from. Called
    /// when the daemon ingests a trace whose evidence lives outside the sessions
    /// root (e.g. a user-chosen `--trace-output`).
    public func registerArtifactRoot(_ directory: URL) {
        let canonical = Self.canonicalPath(directory)
        live.withLock { _ = $0.allowedArtifactRoots.insert(canonical) }
    }

    /// Whether [fileURL] resolves to a file inside one of the allowed artifact
    /// roots. Symlinks and `..` are resolved first so a stored ref cannot escape
    /// the allowlist to read arbitrary files (e.g. an event POSTed by a local
    /// process pointing at `/etc/passwd`).
    public func isArtifactPathAllowed(_ fileURL: URL) -> Bool {
        let target = Self.canonicalComponents(fileURL)
        let roots = live.withLock { $0.allowedArtifactRoots }
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
        let (event, callbacks) = live.withLock { live -> (ReticleEventEnvelope, [Subscriber]) in
            let event = ReticleEventEnvelope(
                id: Self.allocateId(&live.nextSequence),
                ts: currentMillis(),
                session: session,
                target: request.target,
                source: request.source,
                type: request.type,
                payload: request.payload,
                refs: request.refs
            )
            live.buffer.append(event)
            if live.buffer.count > limit {
                live.buffer.removeFirst(live.buffer.count - limit)
            }
            return (event, Array(live.subscribers.values))
        }

        // Encode + write OUTSIDE `lock`: serializing a large network payload
        // under the buffer lock stalled every concurrent reader. Two racing
        // appends may land in the file out of id order (loads sort by id);
        // a failed write leaves the event visible in memory — persistence was
        // always best-effort (appends are not fsync'd).
        let line = try encoder.encode(event) + Data("\n".utf8)
        try writeHandle.withLock { handle in
            let open: FileHandle
            if let handle { open = handle }
            else {
                open = try FileHandle(forWritingTo: eventsFile)
                try open.seekToEnd()
                handle = open
            }
            try open.write(contentsOf: line)
        }

        callbacks.forEach { $0(event) }
        return event
    }

    /// Returns buffered events after `since`; nil returns the whole buffer.
    public func events(since: String? = nil) -> [ReticleEventEnvelope] {
        live.withLock { live in
            guard let since else { return live.buffer }
            return live.buffer.filter { $0.id > since }
        }
    }

    /// Returns one buffered event by daemon-assigned id.
    public func event(id: String) -> ReticleEventEnvelope? {
        live.withLock { $0.buffer.first { $0.id == id } }
    }

    /// Number of events currently retained in memory.
    public var eventCount: Int {
        live.withLock { $0.buffer.count }
    }

    /// Lists all persisted sessions under the same sessions root.
    public func sessionInfos() throws -> [SessionInfo] {
        try Self.sessionInfos(rootDirectory: rootDirectory, currentSession: session)
    }

    /// Loads persisted events for a session id without subscribing to live changes.
    public func historicalEvents(session id: String, since: String? = nil) throws -> [ReticleEventEnvelope] {
        let events: [ReticleEventEnvelope]
        if id == session {
            // The in-memory ring only holds the newest `limit` events, but the
            // full history lives in events.jsonl (appends flush there before
            // returning). Read from disk so the current session answers the
            // same way a historical one does — the buffer is only a fallback
            // if the file can't be read.
            events = (try? Self.loadEvents(session: id, rootDirectory: rootDirectory)) ?? self.events()
        } else {
            events = try Self.loadEvents(session: id, rootDirectory: rootDirectory)
        }
        guard let since else { return events }
        return events.filter { $0.id > since }
    }

    /// Finds a persisted event by id in either the current or a historical session.
    public func historicalEvent(session id: String, eventId: String) throws -> ReticleEventEnvelope? {
        // For the current session, prefer the in-memory buffer, but fall back to
        // disk: an event that has aged out of the bounded ring is still persisted
        // in events.jsonl, and its artifacts must remain fetchable.
        if id == session, let buffered = event(id: eventId) {
            return buffered
        }
        return try Self.loadEvent(session: id, eventId: eventId, rootDirectory: rootDirectory)
    }

    /// Adds a live event subscriber and returns a token for removing it.
    @discardableResult
    public func subscribe(_ subscriber: @escaping Subscriber) -> UUID {
        let token = UUID()
        live.withLock { $0.subscribers[token] = subscriber }
        return token
    }

    /// Removes a live event subscriber.
    public func unsubscribe(_ token: UUID) {
        live.withLock { _ = $0.subscribers.removeValue(forKey: token) }
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
        // Racing appends may persist out of id order (encode happens outside
        // the allocation lock); ids are fixed-width so a string sort restores
        // the true order.
        loaded.sort { $0.id < $1.id }
        live.withLock { live in
            live.buffer = Array(loaded.suffix(limit))
            live.nextSequence = highest + 1
        }
    }

    private static func allocateId(_ nextSequence: inout UInt64) -> String {
        let id = String(format: "evt_%016llu", nextSequence)
        nextSequence += 1
        return id
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
            // Count by scanning lines rather than decoding every event into a
            // model just to size the listing — the panel polls this repeatedly.
            let counts = countEvents(session: id, rootDirectory: rootDirectory)
            let eventsFile = eventsFile(session: id, rootDirectory: rootDirectory)
            let updatedAt = modificationMillis(for: eventsFile) ?? values.contentModificationDate.map(millis)
            return SessionInfo(
                id: id,
                path: url.path,
                eventCount: counts.total,
                actionTraceCount: counts.actionTraces,
                updatedAtMillis: updatedAt,
                isCurrent: id == currentSession
            )
        }
        return infos.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            return ($0.updatedAtMillis ?? 0) > ($1.updatedAtMillis ?? 0)
        }
    }

    /// Cheap event counts for the session listing: total non-empty lines and
    /// lines carrying the action.trace type, streamed in fixed-size chunks so a
    /// multi-MB session file is never materialized as one String per poll.
    private static func countEvents(session id: String, rootDirectory: URL) -> (total: Int, actionTraces: Int) {
        let file = eventsFile(session: id, rootDirectory: rootDirectory)
        let marker = Data("\"type\":\"action.trace\"".utf8)
        var total = 0
        var traces = 0
        do {
            try forEachLine(at: file) { line in
                total += 1
                if line.range(of: marker) != nil { traces += 1 }
                return true
            }
        } catch {
            return (0, 0)
        }
        return (total, traces)
    }

    private static func loadEvents(session id: String, rootDirectory: URL) throws -> [ReticleEventEnvelope] {
        let file = try validatedEventsFile(session: id, rootDirectory: rootDirectory)
        let decoder = JSONDecoder()
        var events: [ReticleEventEnvelope] = []
        // Skip corrupt/partial lines (see loadExistingEvents) instead of throwing,
        // so listing sessions and reading history never fail on one torn line.
        try forEachLine(at: file) { line in
            if let event = try? decoder.decode(ReticleEventEnvelope.self, from: line) {
                events.append(event)
            }
            return true
        }
        // Racing appends may persist out of id order (see loadExistingEvents);
        // ids are fixed-width so a string sort restores the true order.
        events.sort { $0.id < $1.id }
        return events
    }

    /// Finds one persisted event by id without decoding past the hit: only
    /// lines containing the id string are decode candidates, and the scan stops
    /// at the first line whose decoded id matches.
    private static func loadEvent(
        session id: String,
        eventId: String,
        rootDirectory: URL
    ) throws -> ReticleEventEnvelope? {
        let file = try validatedEventsFile(session: id, rootDirectory: rootDirectory)
        // The daemon encodes envelopes compactly, so the id always appears as
        // this exact byte sequence. A payload string could also contain it, so
        // a marker hit is confirmed against the decoded envelope's id.
        let marker = Data("\"id\":\"\(eventId)\"".utf8)
        let decoder = JSONDecoder()
        var found: ReticleEventEnvelope?
        try forEachLine(at: file) { line in
            guard line.range(of: marker) != nil,
                  let event = try? decoder.decode(ReticleEventEnvelope.self, from: line),
                  event.id == eventId else { return true }
            found = event
            return false
        }
        return found
    }

    private static func validatedEventsFile(session id: String, rootDirectory: URL) throws -> URL {
        guard isSafeSessionID(id) else {
            throw EventStoreError.invalidSession(id)
        }
        let file = eventsFile(session: id, rootDirectory: rootDirectory)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw EventStoreError.sessionNotFound(id)
        }
        return file
    }

    /// Reads the file in fixed-size chunks and invokes [body] once per
    /// newline-terminated, non-empty line (plus a trailing unterminated line,
    /// which may be a torn append — callers already tolerate undecodable
    /// lines). Returning `false` from [body] stops the scan early.
    private static func forEachLine(at url: URL, _ body: (Data) -> Bool) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let newline = UInt8(ascii: "\n")
        var pending = Data()
        while let chunk = try handle.read(upToCount: 1 << 16), !chunk.isEmpty {
            pending.append(chunk)
            var cursor = pending.startIndex
            while let breakIndex = pending[cursor...].firstIndex(of: newline) {
                let line = pending.subdata(in: cursor..<breakIndex)
                cursor = pending.index(after: breakIndex)
                if !line.isEmpty, !body(line) { return }
            }
            pending = pending.subdata(in: cursor..<pending.endIndex)
        }
        if !pending.isEmpty {
            _ = body(pending)
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

/// The session store is the network lane's event sink. `emit` is the best-effort
/// façade the proxy handlers call — it swallows the append error (capture must
/// never fail a proxied request), centralizing the `try?` the handlers used to
/// spell out at every call site.
extension EventStore: NetworkEventSink {
    public func emit(_ request: EventPostRequest) {
        _ = try? append(request)
    }
}
