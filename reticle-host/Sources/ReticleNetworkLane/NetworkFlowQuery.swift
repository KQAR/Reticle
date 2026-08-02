import Foundation

/// A filter over the flows the capture engine still holds — "find the exchange I
/// want to replay" without pulling the whole buffer into an agent's context.
///
/// Deliberately scoped to **replayable** flows, which is what makes this a view and
/// not a second source of truth. The session's evidence is `events.jsonl`, and it is
/// complete; the engine's in-memory ring is bounded and ages out, but it is the only
/// thing `replay` can act on (`replay` already fails with "it may have aged out of
/// the in-memory store"). Asking "what can I still replay, matching X" is therefore a
/// question only the ring can answer, and an answer that can't drift from the
/// evidence log because it isn't claiming to be it.
public struct NetworkFlowFilter: Sendable {
    /// Host to match, exactly or as a glob (`*.example.com`).
    public var host: String?
    /// HTTP methods to include, compared case-insensitively.
    public var methods: [String]?
    /// Case-insensitive substring of the absolute URL.
    public var urlContains: String?
    /// Inclusive status bounds. An exact status sets both.
    public var statusMin: Int?
    public var statusMax: Int?
    /// Only exchanges that failed: a transport error, or status >= 400.
    public var onlyErrors: Bool
    /// Only flows started at or after this instant.
    public var since: Date?
    /// Case-insensitive substring of a request or response header. Without a colon it
    /// matches a header's name or its value (`authorization` finds the header,
    /// `Bearer ey` finds the token); with one it splits into `name: value` and both
    /// halves must hit the *same* header, so `x-env: staging` cannot be satisfied by
    /// an `x-env` header plus an unrelated `staging` elsewhere. Loom's semantics
    /// verbatim — this filter runs inside its store, not over a Reticle-side copy.
    public var headerContains: String?
    /// Case-insensitive substring of the captured request *or* response body, matched
    /// over raw bytes (a non-UTF-8 payload is searched too).
    ///
    /// Matched against what was **captured**, not what was on the wire: a body past
    /// the capture cap is recorded as a prefix, so a miss on a flow reporting
    /// `bodyCaptureTruncated` is not proof the bytes never flowed. This is the one
    /// predicate that costs more than a metadata scan — the store hydrates a
    /// candidate's body only after every cheap predicate has already passed.
    public var bodyContains: String?
    /// Newest-first cap on the result count. The filter runs over everything
    /// retained *before* this applies, so a match older than `limit` exchanges is
    /// still findable — the whole point of filtering next to the store.
    public var limit: Int

    public init(
        host: String? = nil,
        methods: [String]? = nil,
        urlContains: String? = nil,
        statusMin: Int? = nil,
        statusMax: Int? = nil,
        onlyErrors: Bool = false,
        since: Date? = nil,
        headerContains: String? = nil,
        bodyContains: String? = nil,
        limit: Int = 50
    ) {
        self.host = host
        self.methods = methods
        self.urlContains = urlContains
        self.statusMin = statusMin
        self.statusMax = statusMax
        self.onlyErrors = onlyErrors
        self.since = since
        self.headerContains = headerContains
        self.bodyContains = bodyContains
        self.limit = max(1, min(limit, 500))
    }
}

/// One matching flow, summarized. Body-free by design: this answers "which exchange
/// do I mean", and the evidence for it already lives in the session's `network.*`
/// events and body artifacts.
public struct NetworkFlowSummary: Codable, Equatable, Sendable {
    public let requestId: String
    public let method: String
    public let url: String
    public let host: String
    public let status: Int?
    public let error: String?
    public let startMillis: Int64
    public let durationMs: Int?
    public let ttfbMs: Int?
    public let receiveMs: Int?
    public let requestBodyBytes: Int?
    public let responseBodyBytes: Int?
    /// True when a capture cap clipped one of this flow's bodies — the same caveat
    /// the capture events carry, so a summary can't read as whole when it isn't.
    public let bodyCaptureTruncated: Bool?
    /// Set when this exchange was imported into the engine (a HAR) instead of
    /// observed on the wire this session, naming where it came from. Absent means
    /// captured live. Imported flows are replayable like any other, which is exactly
    /// why the list has to say which ones they are.
    public let importedFrom: String?
}

/// The result set plus the caveats that make a miss readable.
public struct NetworkFlowQueryResult: Codable, Equatable, Sendable {
    public let flows: [NetworkFlowSummary]
    /// How many the filter matched before `limit` clipped the list, when it did.
    public let truncatedToLimit: Bool
    /// Always true, and always said out loud: these are the flows the capture engine
    /// can still replay, not the session's full evidence. A flow that has aged out of
    /// the engine's bounded ring is absent here while its events remain in
    /// `events.jsonl` — so an empty result means "nothing replayable matches", never
    /// "this never happened".
    public let replayableOnly: Bool
}

/// Read side of the capture lane: find a flow worth replaying, then replay it.
public protocol FlowQuerying: AnyObject, Sendable {
    func listFlows(matching filter: NetworkFlowFilter) throws -> NetworkFlowQueryResult
}
