import Foundation
import Synchronization

/// Stores captured network bodies as session artifacts instead of inline event JSON.
///
/// Bodies are the one artifact class a session writes without bound: one per flow,
/// up to `limitBytes` each, and a verification run can be hours of traffic long.
/// `AutoSession.prune()` cannot help — it evicts whole *past* sessions and
/// deliberately skips the one being written — so the store bounds itself: bodies are
/// dropped oldest-first once the directory exceeds `budgetBytes`.
///
/// Eviction is recorded rather than silent. `events.jsonl` is append-only and an
/// event that has aged out of the in-memory ring must stay fetchable, so a ref whose
/// file is gone cannot be rewritten after the fact; instead every eviction appends a
/// line to `network-bodies/evicted.jsonl`, and a fetch for a missing body reads that
/// ledger to answer "evicted at N bytes" instead of "not found". Absent evidence that
/// says why it is absent is the whole absence vocabulary (`docs/boundaries.md`).
public final class NetworkBodyStore: Sendable {
    struct StoredBody {
        let refName: String
        let path: String
        let bytes: Int
        let truncated: Bool
    }

    /// One eviction *episode* worth of loss, handed to the lane so it can be
    /// republished as a `network.advisory`. Coalesced the same way the capture
    /// backlog's is: a session steadily over budget evicts on nearly every write, and
    /// one advisory per dropped body would be its own flood.
    struct EvictionEpisode {
        let evictedBodiesTotal: Int
        let evictedBytesTotal: Int
    }

    /// Everything the write lock covers, in one value: the FIFO of live artifacts,
    /// their byte total, and the session's eviction bookkeeping. Held in a `Mutex`
    /// because the critical section is the artifact write *plus* the accounting — a
    /// write that lands outside the lock could be evicted before it is recorded.
    private struct Ledger {
        var live: [(url: URL, bytes: Int)] = []
        var liveBytes = 0
        var evictedBodies = 0
        var evictedBytes = 0
        /// True while an eviction run is in progress, so the advisory is emitted on
        /// the episode's opening edge. Cleared by the first write that evicts nothing.
        var episodeOpen = false
        /// Set when an episode opens, cleared by `takeEvictionEpisode()`.
        var announcePending = false
    }

    private let directory: URL
    let limitBytes: Int
    /// Ceiling on the bytes of body artifacts this session keeps on disk. Not a tight
    /// bound: the newest body is never evicted (evicting it would make the write
    /// pointless), so a single body larger than the budget still lands.
    let budgetBytes: Int
    private let state = Mutex(Ledger())

    /// Name of the eviction ledger inside the body directory. Not itself a body, so
    /// it is never evicted; one short line per dropped artifact.
    static let ledgerName = "evicted.jsonl"

    /// Creates a body store below the current session directory.
    init(sessionDirectory: URL,
         limitBytes: Int = 1024 * 1024,
         budgetBytes: Int = NetworkProxyConfiguration.defaultBodyBudgetBytes) {
        directory = sessionDirectory.appendingPathComponent("network-bodies", isDirectory: true)
        self.limitBytes = max(0, limitBytes)
        self.budgetBytes = max(0, budgetBytes)
    }

    /// Writes a request or response body artifact and returns its event ref.
    func store(_ data: Data, requestId: String, role: String) throws -> StoredBody? {
        guard !data.isEmpty else { return nil }
        let safeRole = role == "response" ? "responseBody" : "requestBody"
        let slice = Data(data.prefix(limitBytes))
        return try write(
            slice,
            to: directory.appendingPathComponent("\(requestId)-\(safeRole).bin"),
            refName: "\(safeRole).\(requestId)",
            reportedBytes: data.count
        )
    }

    /// Writes one WebSocket frame's payload as an artifact. Separate from `store` so
    /// the frame role can't be spelled by a caller: the filename is built from the
    /// flow id and an `Int` index, never from free text.
    func storeFrame(_ data: Data, requestId: String, index: Int) throws -> StoredBody? {
        guard !data.isEmpty else { return nil }
        let slice = Data(data.prefix(limitBytes))
        return try write(
            slice,
            to: directory.appendingPathComponent("\(requestId)-wsFrame-\(index).bin"),
            refName: "wsFrame.\(requestId).\(index)",
            reportedBytes: data.count
        )
    }

    /// Writes an already-bounded body prefix for a streamed transfer and reports
    /// the full transfer size. The streaming path caps `prefix` at `limitBytes`
    /// while it forwards every byte to the client, so `bytes` is the true total
    /// and `truncated` reflects whether the stored artifact is shorter than it.
    func store(prefix: Data, totalBytes: Int, requestId: String, role: String) throws -> StoredBody? {
        guard totalBytes > 0 else { return nil }
        let safeRole = role == "response" ? "responseBody" : "requestBody"
        let capped = Data(prefix.prefix(limitBytes))
        return try write(
            capped,
            to: directory.appendingPathComponent("\(requestId)-\(safeRole).bin"),
            refName: "\(safeRole).\(requestId)",
            reportedBytes: totalBytes
        )
    }

    /// Reports an eviction episode exactly once, on its opening edge, and clears the
    /// pending flag. Session-cumulative totals rather than per-episode counts, for the
    /// same reason `droppedFlowsTotal` is: an episode still open has no final size.
    func takeEvictionEpisode() -> EvictionEpisode? {
        state.withLock { ledger in
            guard ledger.announcePending else { return nil }
            ledger.announcePending = false
            return EvictionEpisode(
                evictedBodiesTotal: ledger.evictedBodies,
                evictedBytesTotal: ledger.evictedBytes
            )
        }
    }

    /// Bytes the body at [url] held when it was evicted, or `nil` if this artifact was
    /// never evicted (so a missing file is genuinely missing, not budget-dropped).
    /// Public because the artifact route lives above this module and has only the ref
    /// path to go on.
    public static func evictedBytes(forArtifactAt url: URL) -> Int? {
        let ledger = url.deletingLastPathComponent().appendingPathComponent(ledgerName)
        guard let text = try? String(contentsOf: ledger, encoding: .utf8) else { return nil }
        let name = url.lastPathComponent
        // Newest last, so the last matching line wins if a name were ever reused.
        var bytes: Int?
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["file"] as? String == name else { continue }
            bytes = (object["bytes"] as? NSNumber)?.intValue ?? 0
        }
        return bytes
    }

    /// The one write path: artifact bytes and the accounting that bounds them land
    /// under the same lock, then anything over budget is evicted oldest-first.
    private func write(_ slice: Data, to url: URL, refName: String, reportedBytes: Int) throws -> StoredBody {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledgerURL = directory.appendingPathComponent(Self.ledgerName)
        try state.withLock { ledger in
            try slice.write(to: url, options: .atomic)
            // A re-written body (a streamed response completing after its head) replaces
            // its own entry instead of being counted twice.
            if let index = ledger.live.firstIndex(where: { $0.url == url }) {
                ledger.liveBytes -= ledger.live[index].bytes
                ledger.live.remove(at: index)
            }
            ledger.live.append((url, slice.count))
            ledger.liveBytes += slice.count

            var evictedNow = 0
            // `count > 1`: never evict the body just written — the newest artifact is
            // the one a verification step is about to read.
            while ledger.liveBytes > budgetBytes, ledger.live.count > 1 {
                let oldest = ledger.live.removeFirst()
                ledger.liveBytes -= oldest.bytes
                try? FileManager.default.removeItem(at: oldest.url)
                Self.appendLedgerLine(at: ledgerURL, file: oldest.url.lastPathComponent, bytes: oldest.bytes)
                ledger.evictedBodies += 1
                ledger.evictedBytes += oldest.bytes
                evictedNow += 1
            }
            if evictedNow > 0 {
                if !ledger.episodeOpen { ledger.announcePending = true }
                ledger.episodeOpen = true
            } else {
                ledger.episodeOpen = false
            }
        }
        return StoredBody(
            refName: refName,
            path: url.path,
            bytes: reportedBytes,
            truncated: reportedBytes > slice.count
        )
    }

    /// Appends one eviction record. Best-effort by design: losing the note is worse
    /// than losing the body, but neither may fail a captured request.
    private static func appendLedgerLine(at url: URL, file: String, bytes: Int) {
        let object: [String: Any] = ["file": file, "bytes": bytes]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        guard let lineData = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lineData)
        } else {
            try? lineData.write(to: url, options: .atomic)
        }
    }
}
