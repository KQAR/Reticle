import Foundation
import Testing
@testable import ReticleHostCore
@testable import ReticleNetworkLane

/// Captures the filter the route built, so the query-string parsing is pinned
/// without needing a live capture engine behind it.
private final class StubQuerier: FlowQuerying, @unchecked Sendable {
    private let lock = NSLock()
    private var _received: NetworkFlowFilter?
    var received: NetworkFlowFilter? { lock.withLock { _received } }
    var result: NetworkFlowQueryResult

    init(result: NetworkFlowQueryResult) { self.result = result }

    func listFlows(matching filter: NetworkFlowFilter) throws -> NetworkFlowQueryResult {
        lock.withLock { _received = filter }
        return result
    }
}

private let emptyResult = NetworkFlowQueryResult(flows: [], truncatedToLimit: false, replayableOnly: true)

/// `GET /sessions/current/flows` finds a flow worth replaying. What is Reticle's
/// here (and so pinned here) is the query-string parsing and the honesty of the
/// envelope; the matching itself is the capture engine's.
@Suite("Flow query route")
struct FlowQueryRouteTests {
    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reticle-flowquery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func serve(_ querier: StubQuerier?) throws -> ReticleHttpServer {
        let store = try EventStore(session: "test", rootDirectory: try temporaryDirectory(), limit: 10)
        let server = try ReticleHttpServer(store: store, port: 0)
        server.flowQuerier = querier
        try server.start()
        return server
    }

    @Test func queryParametersBecomeTheFilter() async throws {
        let querier = StubQuerier(result: emptyResult)
        let server = try serve(querier)
        defer { server.stop() }

        let url = URL(string: "http://127.0.0.1:\(server.port)/sessions/current/flows"
            + "?host=*.example.com&method=GET,POST&urlContains=/orders&status=404"
            + "&onlyErrors=true&sinceMillis=1700000000000&limit=7")!
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let filter = try #require(querier.received)
        #expect(filter.host == "*.example.com")
        #expect(filter.methods == ["GET", "POST"])
        #expect(filter.urlContains == "/orders")
        // An exact status sets both bounds — the common case shouldn't need two params.
        #expect(filter.statusMin == 404)
        #expect(filter.statusMax == 404)
        #expect(filter.onlyErrors)
        #expect(filter.since == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(filter.limit == 7)
    }

    @Test func noParametersMeansMatchAllWithADefaultLimit() async throws {
        let querier = StubQuerier(result: emptyResult)
        let server = try serve(querier)
        defer { server.stop() }

        _ = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(server.port)/sessions/current/flows")!)

        let filter = try #require(querier.received)
        #expect(filter.host == nil)
        #expect(filter.methods == nil)
        #expect(filter.statusMin == nil)
        #expect(filter.onlyErrors == false)
        #expect(filter.limit == 50)
    }

    /// An unbounded limit would let one request pull the whole ring into an agent's
    /// context — the exact cost this endpoint exists to avoid.
    @Test func limitIsClampedRatherThanTrusted() {
        #expect(NetworkFlowFilter(limit: 100_000).limit == 500)
        #expect(NetworkFlowFilter(limit: 0).limit == 1)
        #expect(NetworkFlowFilter(limit: -3).limit == 1)
    }

    @Test func aNonNumericLimitIsRejectedRatherThanIgnored() async throws {
        let server = try serve(StubQuerier(result: emptyResult))
        defer { server.stop() }

        let (_, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(server.port)/sessions/current/flows?limit=lots")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
    }

    /// The result must always say it covers only what is still replayable — an empty
    /// list means "nothing replayable matches", never "this never happened", and the
    /// caller can only know that if the envelope says so.
    @Test func theEnvelopeAlwaysDeclaresItsScope() async throws {
        let summary = NetworkFlowSummary(
            requestId: "abc", method: "POST", url: "https://api.example.com/orders",
            host: "api.example.com", status: 500, error: nil, startMillis: 1_700_000_000_000,
            durationMs: 120, ttfbMs: 100, receiveMs: 20,
            requestBodyBytes: 10, responseBodyBytes: 20, bodyCaptureTruncated: true
        )
        let querier = StubQuerier(result: NetworkFlowQueryResult(
            flows: [summary], truncatedToLimit: true, replayableOnly: true))
        let server = try serve(querier)
        defer { server.stop() }

        let (data, _) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(server.port)/sessions/current/flows")!)
        let decoded = try JSONDecoder().decode(NetworkFlowQueryResult.self, from: data)
        #expect(decoded.replayableOnly)
        #expect(decoded.truncatedToLimit)
        #expect(decoded.flows.first?.requestId == "abc")
        #expect(decoded.flows.first?.ttfbMs == 100)
        #expect(decoded.flows.first?.bodyCaptureTruncated == true)
    }

    /// Without a capture proxy there is nothing to list, and saying so beats an
    /// empty list that reads as "no traffic matched".
    @Test func listingWithoutACaptureLaneIsNotFoundRatherThanEmpty() async throws {
        let server = try serve(nil)
        defer { server.stop() }

        let (_, response) = try await URLSession.shared.data(
            from: URL(string: "http://127.0.0.1:\(server.port)/sessions/current/flows")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }
}
