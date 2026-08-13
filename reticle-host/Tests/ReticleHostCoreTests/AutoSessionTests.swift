import Foundation
import Testing
@testable import ReticleHostCore

/// Auto-recording: where traces land when nobody asked, and when they go away.
///
/// The pruning half of this deletes evidence off a user's disk, so what it must
/// never do matters more than what it does — touching a session someone named,
/// or the one currently being written, would lose the exact artifacts a person
/// was in the middle of collecting.
@Suite("Auto session")
struct AutoSessionTests {

    private func temporaryHome() throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reticle-auto-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    /// `auto: true` marks the session the way `currentTraceDirectory()` does.
    /// A session without the marker is one a human made, whatever it is called.
    private func makeSession(_ home: URL, _ name: String, bytes: Int = 0, auto: Bool = true) throws {
        let sessionDir = home.appendingPathComponent("sessions/\(name)", isDirectory: true)
        let dir = sessionDir.appendingPathComponent("traces", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if auto {
            try Data().write(to: sessionDir.appendingPathComponent(AutoSession.markerName))
        }
        if bytes > 0 {
            try Data(repeating: 0x41, count: bytes)
                .write(to: dir.appendingPathComponent("payload.bin"))
        }
    }

    private func sessionNames(_ home: URL) -> [String] {
        let dir = home.appendingPathComponent("sessions", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted()
    }

    @Test func consecutiveActionsJoinOneSessionUntilItGoesIdle() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var clock: Int64 = 1_782_875_000_000
        let session = AutoSession(home: home, now: { clock })

        let first = try #require(session.currentTraceDirectory())
        clock += AutoSession.idleGapMillis - 1
        let sameRun = try #require(session.currentTraceDirectory())
        #expect(first == sameRun, "a pause shorter than the idle gap is still one run")

        // The gap is measured from LAST USE, not from session start: a long run of
        // closely-spaced actions must not get chopped up just for lasting a while.
        clock += AutoSession.idleGapMillis - 1
        #expect(try #require(session.currentTraceDirectory()) == first)

        clock += AutoSession.idleGapMillis + 1
        let nextRun = try #require(session.currentTraceDirectory())
        #expect(nextRun != first, "past the idle gap this is a new run")
    }

    @Test func readingTheLastSessionNeverStartsOne() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let clock: Int64 = 1_782_875_000_000
        let session = AutoSession(home: home, now: { clock })

        // Asking what was recorded, before anything was, is a plain "nothing".
        #expect(session.lastTraceDirectory() == nil)
        #expect(sessionNames(home).isEmpty)

        let recorded = try #require(session.currentTraceDirectory())
        #expect(session.lastTraceDirectory() == recorded)
        #expect(sessionNames(home).count == 1, "reading must not have created a second session")
    }

    @Test func pruningNeverTouchesANamedSession() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeSession(home, "checkout-bug", auto: false)
        try makeSession(home, "checkout-login", auto: false)
        for i in 0..<5 { try makeSession(home, "auto-2026072\(i)-000000") }

        let removed = AutoSession(home: home).prune(keepSessions: 2, budgetBytes: .max)

        #expect(removed.count == 3)
        #expect(removed.allSatisfy { $0.hasPrefix("auto-") })
        // A session someone named is theirs; no disk pressure makes deleting it
        // this code's call.
        #expect(sessionNames(home).contains("checkout-bug"))
        #expect(sessionNames(home).contains("checkout-login"))
    }

    /// The name prefix is a label, not a licence to delete.
    ///
    /// Not hypothetical: this repo's own e2e run leaves a hand-named
    /// `auto-trace-e2e` session under ~/.reticle, and an earlier draft of the
    /// pruner — which matched on the `auto-` prefix — would have deleted it as
    /// one of its own. Eligibility is the marker file this code writes, so a
    /// session Reticle did not create is invisible to pruning no matter what it
    /// is called.
    @Test func pruningIgnoresAnUnmarkedSessionEvenWhenItIsNamedLikeAnAutoOne() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try makeSession(home, "auto-trace-e2e", auto: false)
        for i in 0..<4 { try makeSession(home, "auto-2026072\(i)-000000") }

        let removed = AutoSession(home: home).prune(keepSessions: 0, budgetBytes: .max)

        #expect(!removed.contains("auto-trace-e2e"))
        #expect(sessionNames(home).contains("auto-trace-e2e"))
        #expect(removed.count == 4, "the four it did create are still fair game")
    }

    @Test func pruningNeverTouchesTheSessionBeingWritten() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for i in 0..<4 { try makeSession(home, "auto-2026072\(i)-000000") }
        let current = "auto-20260720-000000" // the OLDEST, so only the exclusion saves it

        let removed = AutoSession(home: home).prune(keepSessions: 1, budgetBytes: .max, excluding: current)

        #expect(!removed.contains(current))
        #expect(sessionNames(home).contains(current))
    }

    @Test func pruningDropsOldestFirstUntilTheByteBudgetIsMet() async throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Names sort chronologically, so lexical order is age order.
        try makeSession(home, "auto-20260721-000000", bytes: 40_000)
        try makeSession(home, "auto-20260722-000000", bytes: 40_000)
        try makeSession(home, "auto-20260723-000000", bytes: 40_000)

        let removed = AutoSession(home: home).prune(keepSessions: .max, budgetBytes: 100_000)

        #expect(removed == ["auto-20260721-000000"], "the oldest goes first, and only as far as needed")
        #expect(sessionNames(home).contains("auto-20260723-000000"))
    }

    @Test func sessionNamesSortChronologically() async {
        let earlier = AutoSession.stampName(1_782_875_000_000)
        let later = AutoSession.stampName(1_782_875_000_000 + 86_400_000)
        // Pruning relies on this: it takes the lexically smallest names as oldest.
        #expect(earlier < later)
    }
}
