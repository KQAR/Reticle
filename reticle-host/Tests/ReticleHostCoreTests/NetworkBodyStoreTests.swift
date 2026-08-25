import Foundation
import Testing
@testable import ReticleNetworkLane

/// The body store is the one artifact writer with no expiry above it: `AutoSession`
/// prunes past sessions and deliberately skips the one being written, so a long
/// verification run used to grow `network-bodies/` until the disk said no. These pin
/// the budget, the order it drops in, and — the part that makes it evidence rather
/// than a silent cleanup — that an evicted body can still say it was evicted.
@Suite("Network body store")
struct NetworkBodyStoreTests {

    private func temporarySession() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reticle-body-store-\(UUID().uuidString)", isDirectory: true)
    }

    private func bodiesDirectory(_ session: URL) -> URL {
        session.appendingPathComponent("network-bodies", isDirectory: true)
    }

    @Test func bodiesUnderBudgetAreAllKept() throws {
        let session = temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }
        let store = NetworkBodyStore(sessionDirectory: session, limitBytes: 1_024, budgetBytes: 1_024)

        for index in 0..<4 {
            _ = try store.store(Data(repeating: 0x41, count: 100), requestId: "flow-\(index)", role: "response")
        }

        let files = try FileManager.default.contentsOfDirectory(atPath: bodiesDirectory(session).path)
        #expect(files.count == 4)
        #expect(store.takeEvictionEpisode() == nil, "nothing was evicted, so nothing to advise about")
    }

    @Test func theOldestBodiesGoFirstWhenTheBudgetIsExceeded() throws {
        let session = temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }
        // Budget holds two 100-byte bodies; the third pushes the first out.
        let store = NetworkBodyStore(sessionDirectory: session, limitBytes: 1_024, budgetBytes: 250)

        for index in 0..<3 {
            _ = try store.store(Data(repeating: 0x41, count: 100), requestId: "flow-\(index)", role: "response")
        }

        let directory = bodiesDirectory(session)
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(!files.contains("flow-0-responseBody.bin"), "the oldest body is the one that goes")
        #expect(files.contains("flow-1-responseBody.bin"))
        #expect(files.contains("flow-2-responseBody.bin"), "the body just written is never the one evicted")
    }

    /// A single body larger than the whole budget still lands: evicting the artifact a
    /// verification step is about to read would make the write pointless, and the
    /// budget is a ceiling on accumulation, not a per-body limit (`limitBytes` is that).
    @Test func aBodyLargerThanTheBudgetIsStillStored() throws {
        let session = temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }
        let store = NetworkBodyStore(sessionDirectory: session, limitBytes: 4_096, budgetBytes: 100)

        let stored = try store.store(Data(repeating: 0x41, count: 1_000), requestId: "big", role: "response")

        #expect(stored != nil)
        #expect(FileManager.default.fileExists(atPath: stored!.path))
    }

    /// The point of the ledger: `events.jsonl` is append-only and an event that has
    /// aged out of the in-memory ring must stay fetchable, so the ref of an evicted
    /// body cannot be rewritten. The ledger is what lets a fetch answer "evicted at N
    /// bytes" instead of "not found" — the difference between bounded evidence and
    /// missing evidence.
    @Test func anEvictedBodyReportsHowManyBytesItHeld() throws {
        let session = temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }
        let store = NetworkBodyStore(sessionDirectory: session, limitBytes: 1_024, budgetBytes: 150)

        let first = try store.store(Data(repeating: 0x41, count: 100), requestId: "flow-0", role: "response")
        _ = try store.store(Data(repeating: 0x42, count: 100), requestId: "flow-1", role: "response")

        let evictedURL = URL(fileURLWithPath: first!.path)
        #expect(!FileManager.default.fileExists(atPath: evictedURL.path))
        #expect(NetworkBodyStore.evictedBytes(forArtifactAt: evictedURL) == 100)
        // A body that was never stored at all is a different answer, not the same one.
        let neverStored = bodiesDirectory(session).appendingPathComponent("flow-9-responseBody.bin")
        #expect(NetworkBodyStore.evictedBytes(forArtifactAt: neverStored) == nil)
    }

    /// One advisory per episode, not per dropped body: a session steadily over budget
    /// evicts on nearly every write, and an event each time would bury the traffic it
    /// is describing — the same reason the capture backlog reports two edges.
    @Test func evictionAnnouncesOncePerEpisode() throws {
        let session = temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }
        let store = NetworkBodyStore(sessionDirectory: session, limitBytes: 1_024, budgetBytes: 150)

        _ = try store.store(Data(repeating: 0x41, count: 100), requestId: "flow-0", role: "response")
        #expect(store.takeEvictionEpisode() == nil)

        _ = try store.store(Data(repeating: 0x42, count: 100), requestId: "flow-1", role: "response")
        let opening = store.takeEvictionEpisode()
        #expect(opening?.evictedBodiesTotal == 1)
        #expect(opening?.evictedBytesTotal == 100)

        // Still over budget, still evicting — the episode is open, so it stays silent
        // while the totals keep climbing.
        _ = try store.store(Data(repeating: 0x43, count: 100), requestId: "flow-2", role: "response")
        #expect(store.takeEvictionEpisode() == nil, "an open episode is announced once")

        // A write that evicts nothing closes the episode, so the next eviction is a
        // new one and gets said out loud again — with cumulative totals.
        _ = try store.store(Data(repeating: 0x44, count: 1), requestId: "flow-3", role: "response")
        #expect(store.takeEvictionEpisode() == nil)
        _ = try store.store(Data(repeating: 0x45, count: 100), requestId: "flow-4", role: "response")
        let reopened = store.takeEvictionEpisode()
        #expect(reopened != nil, "a fresh episode is announced again")
        #expect((reopened?.evictedBodiesTotal ?? 0) >= 3)
    }

    /// A streamed response is written twice — once for the head, once on completion —
    /// and double-counting the second write would evict live bodies to make room for
    /// bytes that were already accounted for.
    @Test func rewritingTheSameBodyDoesNotDoubleCountItsBytes() throws {
        let session = temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }
        let store = NetworkBodyStore(sessionDirectory: session, limitBytes: 1_024, budgetBytes: 250)

        let first = try store.store(Data(repeating: 0x41, count: 100), requestId: "flow-0", role: "response")
        for _ in 0..<5 {
            _ = try store.store(prefix: Data(repeating: 0x42, count: 100), totalBytes: 100,
                                requestId: "flow-1", role: "response")
        }

        #expect(FileManager.default.fileExists(atPath: first!.path),
                "re-writing one body must not evict the other")
        #expect(store.takeEvictionEpisode() == nil)
    }

    /// WebSocket frames go through the same accounting — a chatty socket is the most
    /// likely way to blow the budget, so it must not be the one path that bypasses it.
    @Test func webSocketFramesShareTheBudget() throws {
        let session = temporarySession()
        defer { try? FileManager.default.removeItem(at: session) }
        let store = NetworkBodyStore(sessionDirectory: session, limitBytes: 1_024, budgetBytes: 150)

        let first = try store.storeFrame(Data(repeating: 0x41, count: 100), requestId: "socket", index: 0)
        _ = try store.storeFrame(Data(repeating: 0x42, count: 100), requestId: "socket", index: 1)

        #expect(!FileManager.default.fileExists(atPath: first!.path))
        #expect(NetworkBodyStore.evictedBytes(forArtifactAt: URL(fileURLWithPath: first!.path)) == 100)
    }
}
