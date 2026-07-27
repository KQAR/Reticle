import Foundation

/// Where action traces go when nobody asked for a specific place.
///
/// Recording used to require `reticle serve` to be running: `act` looked for a
/// live daemon, and with none it recorded nothing unless the caller passed
/// `--trace-output` by hand. So the sessions with no evidence were exactly the
/// ad-hoc ones — an agent poking at a screen, which is the case you most want to
/// reconstruct afterwards. This makes recording the default and gives the
/// artifacts somewhere to live and a reason to eventually go away.
///
/// A daemon session still wins when one is running; this only fills the gap.
public struct AutoSession {
    /// Start a new auto session once the previous one has been idle this long.
    /// Long enough that a pause for thought stays in one session, short enough
    /// that yesterday's poking is not still accumulating into today's.
    public static let idleGapMillis: Int64 = 15 * 60 * 1000

    /// How many auto sessions to keep. Named sessions are never counted or
    /// pruned — the user made those on purpose.
    public static let keepSessions = 20

    /// Total budget for auto sessions on disk. Snapshots and screenshots run
    /// ~230KB per action, so an unattended agent can produce gigabytes in an
    /// afternoon; something has to bound it.
    public static let budgetBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Auto sessions are prefixed for readability and chronological sorting.
    /// The prefix is NOT what makes a session prunable — see `markerName`.
    public static let prefix = "auto-"

    /// Written into every session this code creates, and the only thing that
    /// makes a session eligible for pruning.
    ///
    /// The prefix alone was not enough, and not hypothetically: this repo's own
    /// e2e run leaves a hand-named `auto-trace-e2e` session behind, which a
    /// name-pattern rule would have happily deleted as "one of ours". Deletion
    /// must be gated on evidence that Reticle created the thing, not on the
    /// directory looking like it might have.
    public static let markerName = ".reticle-auto-session"

    private let home: URL
    private let now: () -> Int64

    public init(home: URL = DaemonDiscovery.reticleHome(), now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.home = home
        self.now = now
    }

    private var pointerURL: URL { home.appendingPathComponent("auto-session.json") }
    private var sessionsURL: URL { home.appendingPathComponent("sessions", isDirectory: true) }

    private struct Pointer: Codable {
        var session: String
        var lastUsedAtMillis: Int64
    }

    /// The auto session to record into, creating or rolling one as needed, and
    /// touching its pointer so the next command within the idle gap joins it.
    ///
    /// Returns nil only if `~/.reticle` cannot be written — recording is
    /// best-effort evidence, never a reason for an action to fail.
    public func currentTraceDirectory() -> URL? {
        let session = rollIfIdle()
        let sessionDir = sessionsURL.appendingPathComponent(session, isDirectory: true)
        let dir = sessionDir.appendingPathComponent("traces", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        // Best-effort: a session with no marker is simply never pruned, which is
        // the safe direction to fail in.
        let marker = sessionDir.appendingPathComponent(Self.markerName)
        if !FileManager.default.fileExists(atPath: marker.path) {
            try? Data().write(to: marker)
        }
        return dir
    }

    /// The most recently used auto session's trace directory, without creating
    /// or rolling anything. Used by readers (`reticle trace log`) so asking what
    /// was recorded never starts a new recording.
    public func lastTraceDirectory() -> URL? {
        guard let pointer = readPointer() else { return nil }
        let dir = sessionsURL
            .appendingPathComponent(pointer.session, isDirectory: true)
            .appendingPathComponent("traces", isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }

    private func rollIfIdle() -> String {
        let stamp = now()
        if let pointer = readPointer(), stamp - pointer.lastUsedAtMillis < Self.idleGapMillis {
            writePointer(Pointer(session: pointer.session, lastUsedAtMillis: stamp))
            return pointer.session
        }
        let session = Self.prefix + Self.stampName(stamp)
        writePointer(Pointer(session: session, lastUsedAtMillis: stamp))
        return session
    }

    /// `auto-20260727-184455`, sortable and readable. Built by hand rather than
    /// with a locale-sensitive DateFormatter so a session name never depends on
    /// the machine's region settings.
    static func stampName(_ millis: Int64) -> String {
        var seconds = time_t(millis / 1000)
        var parts = tm()
        localtime_r(&seconds, &parts)
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday,
            parts.tm_hour, parts.tm_min, parts.tm_sec
        )
    }

    private func readPointer() -> Pointer? {
        guard let data = try? Data(contentsOf: pointerURL) else { return nil }
        return try? JSONDecoder().decode(Pointer.self, from: data)
    }

    private func writePointer(_ pointer: Pointer) {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(pointer) else { return }
        try? data.write(to: pointerURL, options: [.atomic])
    }

    // MARK: - retention

    /// Prune auto sessions down to the count and byte budgets, oldest first.
    ///
    /// Deliberately narrow: only directories under `sessions/` carrying the
    /// `markerName` file this code writes, and never the one currently being
    /// written. A session the user named — `reticle serve --session checkout-bug`
    /// — is theirs, and no amount of disk pressure makes deleting it this code's
    /// decision.
    ///
    /// Returns the names it removed, so a caller can say so rather than have
    /// evidence disappear silently.
    @discardableResult
    public func prune(keepSessions: Int = AutoSession.keepSessions,
                      budgetBytes: Int64 = AutoSession.budgetBytes,
                      excluding current: String? = nil) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: sessionsURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        // Name-sortable timestamps mean lexicographic order is chronological.
        let autos = entries
            .filter { $0.lastPathComponent != current }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent(Self.markerName).path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var doomed: [URL] = []
        if autos.count > keepSessions {
            doomed.append(contentsOf: autos.prefix(autos.count - keepSessions))
        }
        var survivors = autos.filter { url in !doomed.contains(url) }

        // Then, oldest-first, until the rest fit the byte budget.
        var sizes = survivors.map { (url: $0, bytes: directorySize($0)) }
        var total = sizes.reduce(0) { $0 + $1.bytes }
        while total > budgetBytes, !sizes.isEmpty {
            let oldest = sizes.removeFirst()
            doomed.append(oldest.url)
            total -= oldest.bytes
        }
        survivors = sizes.map { $0.url }

        var removed: [String] = []
        for url in doomed where (try? fm.removeItem(at: url)) != nil {
            removed.append(url.lastPathComponent)
        }
        return removed
    }

    private func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let walker = fm.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let child as URL in walker {
            let values = try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
