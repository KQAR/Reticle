import Foundation
import LoomSharedModels
import ReticleHostShared
import Testing
@testable import ReticleNetworkLane

/// Collects what the lane emits, standing in for the daemon's `EventStore`.
private final class RecordingSink: NetworkEventSink, @unchecked Sendable {
    let sessionDirectory: URL
    private let lock = NSLock()
    private var events: [EventPostRequest] = []

    init() {
        sessionDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reticle-lane-test-\(UUID().uuidString)", isDirectory: true)
    }

    func emit(_ request: EventPostRequest) {
        lock.withLock { events.append(request) }
    }

    var recorded: [EventPostRequest] { lock.withLock { events } }

    func ofType(_ type: String) -> [EventPostRequest] { recorded.filter { $0.type == type } }

    func cleanUp() { try? FileManager.default.removeItem(at: sessionDirectory) }
}

private func number(_ event: EventPostRequest, _ key: String) -> Double? {
    if case .number(let value)? = event.payload[key] { return value }
    return nil
}

private func string(_ event: EventPostRequest, _ key: String) -> String? {
    if case .string(let value)? = event.payload[key] { return value }
    return nil
}

private func bool(_ event: EventPostRequest, _ key: String) -> Bool? {
    if case .bool(let value)? = event.payload[key] { return value }
    return nil
}

private func makeLane(_ sink: RecordingSink) -> LoomCaptureLane {
    LoomCaptureLane(store: sink, configuration: NetworkProxyConfiguration(port: 0))
}

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

/// The lane turns Loom `Flow`s into `network.*` evidence. These drive `handle`
/// directly with synthesized flows, which is the only way to reach the WebSocket
/// and timing paths — the proxy e2e opens no socket and cannot force a cap.
@Suite("Loom capture lane")
struct LoomCaptureLaneTests {
    // MARK: - Response timing

    @Test func responseCarriesTtfbAndReceiveSpans() {
        let sink = RecordingSink()
        defer { sink.cleanUp() }
        let lane = makeLane(sink)

        lane.handle(Flow(
            request: CapturedRequest(method: "GET", url: "https://api.example.com/slow", headers: []),
            startedAt: epoch,
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: epoch.addingTimeInterval(2.0)),
            firstByteAt: epoch.addingTimeInterval(1.5)
        ))

        let response = sink.ofType("network.response").last
        #expect(response != nil)
        // 1.5s of server think-time, 0.5s of transfer — the split `durationMs` alone
        // cannot express, and the whole reason these fields exist.
        #expect(number(response!, "ttfbMs") == 1500)
        #expect(number(response!, "receiveMs") == 500)
        #expect(number(response!, "durationMs") == 2000)
    }

    /// A flow that failed before any response head has no TTFB to report, and
    /// inventing one from the completion stamp would be a guess.
    @Test func aFlowWithNoResponseHeadReportsNoTtfb() {
        let sink = RecordingSink()
        defer { sink.cleanUp() }
        let lane = makeLane(sink)

        lane.handle(Flow(
            request: CapturedRequest(method: "GET", url: "https://api.example.com/dead", headers: []),
            startedAt: epoch,
            outcome: .failed(FlowError("connection refused"), at: epoch.addingTimeInterval(0.3), partialResponse: nil)
        ))

        let error = sink.ofType("network.error").last
        #expect(error != nil)
        #expect(error!.payload["ttfbMs"] == nil)
        #expect(error!.payload["receiveMs"] == nil)
        #expect(number(error!, "durationMs") == 300)
    }

    // MARK: - WebSocket frames

    @Test func openSocketEmitsFramesWithoutWaitingForClose() {
        let sink = RecordingSink()
        defer { sink.cleanUp() }
        let lane = makeLane(sink)
        let id = UUID()

        lane.handle(socket(id: id, messages: [
            frame(.clientToServer, .text, "subscribe", at: 0.1),
            frame(.serverToClient, .text, "tick-1", at: 0.2)
        ]))

        let frames = sink.ofType("network.websocket")
        #expect(frames.count == 2)
        #expect(string(frames[0], "direction") == "clientToServer")
        #expect(string(frames[0], "textPreview") == "subscribe")
        #expect(number(frames[0], "frameIndex") == 0)
        #expect(string(frames[1], "direction") == "serverToClient")
        #expect(string(frames[1], "textPreview") == "tick-1")
        // The socket is still open: no completion event yet, but the evidence is here.
        #expect(sink.ofType("network.response").isEmpty)
        // The upgrade itself is still an ordinary request event.
        #expect(sink.ofType("network.request").count == 1)
    }

    /// Loom re-sends the whole cumulative frame array on every update. Without a
    /// per-socket cursor every frame would be re-emitted on every subsequent frame.
    @Test func cumulativeUpdatesEmitOnlyTheNewFrames() {
        let sink = RecordingSink()
        defer { sink.cleanUp() }
        let lane = makeLane(sink)
        let id = UUID()

        let first = frame(.clientToServer, .text, "one", at: 0.1)
        let second = frame(.serverToClient, .text, "two", at: 0.2)
        let third = frame(.serverToClient, .text, "three", at: 0.3)
        lane.handle(socket(id: id, messages: [first]))
        lane.handle(socket(id: id, messages: [first, second]))
        lane.handle(socket(id: id, messages: [first, second, third]))

        let frames = sink.ofType("network.websocket")
        #expect(frames.count == 3)
        #expect(frames.map { string($0, "textPreview") } == ["one", "two", "three"])
        #expect(frames.map { number($0, "frameIndex") } == [0, 1, 2])
    }

    /// Loom's own cap (10k frames / 5 MB) can bite on a few large frames, long before
    /// Reticle's. The socket is still open and still talking, so that has to be said
    /// out loud rather than left as a gap in the frame sequence.
    @Test func loomsDroppedFramesAreAnnouncedOnce() {
        let sink = RecordingSink()
        defer { sink.cleanUp() }
        let lane = makeLane(sink)
        let id = UUID()
        let one = frame(.serverToClient, .text, "big", at: 0.1)

        lane.handle(socket(id: id, messages: [one], dropped: 7))
        lane.handle(socket(id: id, messages: [one], dropped: 9))

        let notices = sink.ofType("network.websocket").filter { bool($0, "capReached") == true }
        #expect(notices.count == 1)
        #expect(number(notices[0], "framesNotRecorded") == 7)
        #expect(number(notices[0], "framesRecorded") == 1)
    }

    /// Reticle's own cap exists so one chatty socket can't bury the session. Hitting
    /// it must produce evidence naming itself — silence would read as a quiet socket.
    @Test func reticlesOwnFrameCapAnnouncesItselfAndStopsEmitting() {
        let sink = RecordingSink()
        defer { sink.cleanUp() }
        let lane = makeLane(sink)
        let id = UUID()
        let many = (0..<1200).map { frame(.serverToClient, .text, "f\($0)", at: Double($0) / 100) }

        lane.handle(socket(id: id, messages: many))

        let all = sink.ofType("network.websocket")
        let notices = all.filter { bool($0, "capReached") == true }
        #expect(notices.count == 1)
        // 1000 frames emitted, then the notice — not 1200.
        #expect(all.count == 1001)
        #expect(number(notices[0], "framesRecorded") == 1000)

        // Still capped after more frames arrive, and still announced only once.
        lane.handle(socket(id: id, messages: many + [frame(.serverToClient, .text, "later", at: 99)]))
        #expect(sink.ofType("network.websocket").filter { bool($0, "capReached") == true }.count == 1)
    }

    /// A frame too big to sit inline keeps its bytes as an artifact, and says the
    /// preview is a prefix — the same "a clipped thing must name itself" rule the
    /// body path follows.
    @Test func oversizeTextFrameStoresAnArtifactAndMarksThePreviewTruncated() throws {
        let sink = RecordingSink()
        defer { sink.cleanUp() }
        let lane = makeLane(sink)
        let big = String(repeating: "x", count: 2048)

        lane.handle(socket(id: UUID(), messages: [frame(.serverToClient, .text, big, at: 0.1)]))

        let event = try #require(sink.ofType("network.websocket").first)
        #expect(number(event, "bytes") == 2048)
        #expect(bool(event, "textPreviewTruncated") == true)
        #expect(string(event, "textPreview")?.count == 512)
        let ref = try #require(event.refs.first)
        #expect(ref.key.hasPrefix("wsFrame."))
        #expect(FileManager.default.fileExists(atPath: ref.value))
    }

    /// A small frame is wholly inside its event, so a chatty socket doesn't strew
    /// thousands of artifact files across the session directory.
    @Test func smallFrameCarriesNoArtifact() {
        let sink = RecordingSink()
        defer { sink.cleanUp() }
        let lane = makeLane(sink)

        lane.handle(socket(id: UUID(), messages: [frame(.clientToServer, .text, "ping", at: 0.1)]))

        #expect(sink.ofType("network.websocket").first?.refs.isEmpty == true)
    }

    /// A binary frame has no text reading; reporting one would be a guess dressed as
    /// an observation. Its size and its bytes are still evidence.
    @Test func binaryFrameReportsSizeButNoTextPreview() {
        let sink = RecordingSink()
        defer { sink.cleanUp() }
        let lane = makeLane(sink)
        let payload = Data((0..<900).map { UInt8($0 % 256) })

        lane.handle(socket(id: UUID(), messages: [WebSocketMessage(
            direction: .serverToClient, kind: .binary, payload: payload, timestamp: epoch
        )]))

        let event = sink.ofType("network.websocket").first
        #expect(event != nil)
        #expect(string(event!, "kind") == "binary")
        #expect(number(event!, "bytes") == 900)
        #expect(event!.payload["textPreview"] == nil)
    }

    // MARK: - Capture backlog

    /// The stream loop must not do the work. Artifact writes happen on the worker,
    /// so the engine's bounded `AsyncStream` is drained immediately and never gets
    /// the chance to drop flows the subscriber can't detect.
    @Test func enqueuedFlowsAreProcessedOffTheStream() {
        let sink = RecordingSink()
        defer { sink.cleanUp() }
        let lane = makeLane(sink)

        lane.enqueue(Flow(
            request: CapturedRequest(method: "GET", url: "https://api.example.com/a", headers: []),
            startedAt: epoch,
            outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: epoch.addingTimeInterval(0.1))
        ))
        // Nothing was emitted synchronously on the caller's thread; the worker owns it.
        lane.waitForDrain()

        #expect(sink.ofType("network.request").count == 1)
        #expect(sink.ofType("network.response").count == 1)
    }

    /// A full backlog drops flows — a bounded queue is a deliberate memory choice.
    /// What it must never do is drop them quietly: a gap in the evidence would
    /// otherwise be indistinguishable from traffic that never happened.
    @Test func aFullBacklogAnnouncesItselfInTheEvidence() {
        let sink = RecordingSink()
        defer { sink.cleanUp() }
        let lane = makeLane(sink)

        lane.suspendDrainForTesting()
        for index in 0..<4_200 {
            lane.enqueue(Flow(
                request: CapturedRequest(method: "GET", url: "https://api.example.com/\(index)", headers: []),
                startedAt: epoch,
                outcome: .completed(CapturedResponse(statusCode: 200, headers: []), at: epoch)
            ))
        }

        let opening = sink.ofType("network.advisory")
        #expect(opening.count == 1, "one advisory per overflow episode, not one per dropped flow")
        #expect(string(opening[0], "kind") == "capture-backlog-overflow")
        // The size of the gap is not knowable yet — the episode is still open — and
        // guessing a final number here would be worse than saying "at least this".
        #expect(opening[0].payload["droppedFlows"] == nil)
        #expect(number(opening[0], "droppedFlowsTotal") == 1)

        lane.resumeDrainForTesting()
        lane.waitForDrain()

        // Recovery is where the extent becomes a fact: 4200 offered, 4096 accepted.
        let advisories = sink.ofType("network.advisory")
        #expect(advisories.count == 2)
        #expect(string(advisories[1], "kind") == "capture-backlog-recovered")
        #expect(number(advisories[1], "droppedFlows") == 104)
        #expect(number(advisories[1], "droppedFlowsTotal") == 104)
        // Every accepted flow still produced its evidence; only the overflow was lost.
        #expect(sink.ofType("network.request").count == 4_096)
    }

    // MARK: - Fixtures

    private func frame(
        _ direction: WebSocketMessage.Direction,
        _ kind: WebSocketMessage.Kind,
        _ text: String,
        at offset: TimeInterval
    ) -> WebSocketMessage {
        WebSocketMessage(
            direction: direction,
            kind: kind,
            payload: Data(text.utf8),
            timestamp: epoch.addingTimeInterval(offset)
        )
    }

    private func socket(id: UUID, messages: [WebSocketMessage], dropped: Int? = nil) -> Flow {
        Flow(
            id: id,
            request: CapturedRequest(method: "GET", url: "wss://api.example.com/live", headers: []),
            startedAt: epoch,
            outcome: .streaming(CapturedResponse(statusCode: 101, headers: [])),
            webSocketMessages: messages,
            webSocketDroppedMessages: dropped
        )
    }
}
