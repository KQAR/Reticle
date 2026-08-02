import Foundation
import ReticleHostShared

/// Event kinds emitted by the host proxy into the daemon event bus.
enum NetworkEventType: String {
    case request = "network.request"
    case response = "network.response"
    case error = "network.error"
    /// A replayed exchange plus its diff against the original flow.
    case replay = "network.replay"
    /// One frame on an open WebSocket, or the notice that frames stopped being
    /// recorded. A socket's upgrade is still an ordinary `network.request`/`.response`
    /// pair (status 101) — these carry what happened *inside* it.
    case webSocket = "network.websocket"
    /// The capture lane reporting on itself — currently only that it had to drop
    /// flows. Capture degrading is a fact about the evidence, so it belongs in the
    /// evidence rather than in a log line nobody reads.
    case advisory = "network.advisory"
}

/// The capture lane saying something about its own fidelity.
///
/// Loss is reported as two edges rather than one event per dropped flow, which would
/// make a drop storm its own flood: `capture-backlog-overflow` the moment recording
/// starts falling behind, and `capture-backlog-recovered` once it catches up, which
/// is the first point at which the size of the gap is actually known. A session that
/// ends mid-episode therefore has an overflow with no recovery — the honest reading
/// of that is "still dropping when the session ended", and the running total says how
/// much had been lost by then.
struct NetworkAdvisoryPayload {
    /// `capture-backlog-overflow` | `capture-backlog-recovered`. A closed set, so a
    /// consumer can switch on it.
    let kind: String
    let message: String
    /// Flows lost during the episode that just ended. Present on `recovered`, absent
    /// on `overflow`, where it is not yet knowable.
    var droppedFlows: Int?
    /// Flows lost this session so far, at the moment of the advisory.
    let droppedFlowsTotal: Int

    var json: [String: JSONValue] {
        var values: [String: JSONValue] = [
            "kind": .string(kind),
            "message": .string(message),
            "droppedFlowsTotal": .number(Double(droppedFlowsTotal))
        ]
        if let droppedFlows { values["droppedFlows"] = .number(Double(droppedFlows)) }
        return values
    }
}

/// Normalized network transaction metadata stored in `network.*` payloads.
struct NetworkEventPayload {
    let requestId: String
    let scheme: String
    let method: String
    let url: String
    let host: String
    let port: Int
    let path: String
    let startMillis: Int64
    /// When the response *head* came back. Splits the exchange into server think-time
    /// and transfer time, which `durationMs` alone cannot: "this call is slow" has a
    /// different cause depending on which half it lands in. Nil while pending, for a
    /// flow that failed before any head, and for a blind CONNECT tunnel.
    var firstByteMillis: Int64?
    var endMillis: Int64?
    var status: Int?
    var error: String?
    var tunnel: Bool
    var mitm: Bool
    var requestHeaders: [String: String]?
    var responseHeaders: [String: String]?
    var requestBodyBytes: Int?
    var responseBodyBytes: Int?
    var requestBodyTruncated: Bool?
    var responseBodyTruncated: Bool?
    /// True when a traffic rule acted on this exchange (mock, block, mapRemote, or a
    /// request/response modifier), regardless of which route fired.
    var ruleApplied: Bool?
    /// The id of the rule that acted, present alongside `ruleApplied`.
    var ruleId: String?
    /// Which route fired: `mock` | `block` | `mapRemote` | `passthrough`.
    var ruleAction: String?
    /// The referenced response value id, present only when `ruleAction == "mock"`.
    var mockValueId: String?
    /// On a `network.replay` event, the source flow id this was replayed from.
    var replayedFrom: String?
    /// Names the file this exchange was imported from (a HAR loaded into the capture
    /// engine) when it did NOT happen on this machine's wire during this session.
    /// Loom puts imported flows on the same live stream as captured ones — that is
    /// deliberate on its side, they are meant to be inspectable and replayable the
    /// same way — so without this field someone else's capture would read as evidence
    /// of what the app under test just did.
    var importedFrom: String?
    /// On a `network.replay` event, the diff of the replayed response vs the original.
    var diff: NetworkReplayDiff?

    /// Converts the payload into daemon JSON fields.
    var json: [String: JSONValue] {
        var values: [String: JSONValue] = [
            "requestId": .string(requestId),
            "scheme": .string(scheme),
            "method": .string(method),
            "url": .string(url),
            "host": .string(host),
            "port": .number(Double(port)),
            "path": .string(path),
            "startMillis": .number(Double(startMillis)),
            "tunnel": .bool(tunnel),
            "mitm": .bool(mitm)
        ]
        if let endMillis {
            values["endMillis"] = .number(Double(endMillis))
            values["durationMs"] = .number(Double(max(0, endMillis - startMillis)))
        }
        // Emitted like `durationMs`: the absolute stamp plus the spans derived from it,
        // so a reader never has to subtract. `receiveMs` needs both ends, so a flow that
        // got a head but never completed carries `ttfbMs` alone rather than a guess.
        if let firstByteMillis {
            values["firstByteMillis"] = .number(Double(firstByteMillis))
            values["ttfbMs"] = .number(Double(max(0, firstByteMillis - startMillis)))
            if let endMillis {
                values["receiveMs"] = .number(Double(max(0, endMillis - firstByteMillis)))
            }
        }
        if let status { values["status"] = .number(Double(status)) }
        if let error { values["error"] = .string(error) }
        if let requestHeaders { values["requestHeaders"] = .object(requestHeaders.mapValues(JSONValue.string)) }
        if let responseHeaders { values["responseHeaders"] = .object(responseHeaders.mapValues(JSONValue.string)) }
        if let requestBodyBytes { values["requestBodyBytes"] = .number(Double(requestBodyBytes)) }
        if let responseBodyBytes { values["responseBodyBytes"] = .number(Double(responseBodyBytes)) }
        if let requestBodyTruncated { values["requestBodyTruncated"] = .bool(requestBodyTruncated) }
        if let responseBodyTruncated { values["responseBodyTruncated"] = .bool(responseBodyTruncated) }
        if let ruleApplied { values["ruleApplied"] = .bool(ruleApplied) }
        if let ruleId { values["ruleId"] = .string(ruleId) }
        if let ruleAction { values["ruleAction"] = .string(ruleAction) }
        if let mockValueId { values["mockValueId"] = .string(mockValueId) }
        if let replayedFrom { values["replayedFrom"] = .string(replayedFrom) }
        if let importedFrom { values["importedFrom"] = .string(importedFrom) }
        if let diff {
            var d: [String: JSONValue] = [
                "statusChanged": .bool(diff.statusChanged),
                "bodyChanged": .bool(diff.bodyChanged),
                "bodyBytesFrom": .number(Double(diff.bodyBytesFrom)),
                "bodyBytesTo": .number(Double(diff.bodyBytesTo)),
                "headersAdded": .array(diff.headersAdded.map(JSONValue.string)),
                "headersRemoved": .array(diff.headersRemoved.map(JSONValue.string)),
                "headersChanged": .array(diff.headersChanged.map(JSONValue.string))
            ]
            if let from = diff.statusFrom { d["statusFrom"] = .number(Double(from)) }
            if let to = diff.statusTo { d["statusTo"] = .number(Double(to)) }
            // Must survive into the event: a consumer reading `bodyChanged: false`
            // off the wire has no other way to learn the comparison was made on
            // prefixes, and would read an unverifiable match as a match.
            if let partial = diff.bodyComparisonPartial { d["bodyComparisonPartial"] = .bool(partial) }
            values["diff"] = .object(d)
        }
        return values
    }
}

/// Builds event requests for network proxy observations.
/// One WebSocket frame observed on an open socket, or — with `capReached` — the
/// notice that no further frames on this socket will be recorded.
///
/// Frames are their own event rather than an array on the socket's flow because the
/// socket may never close: an event per frame is evidence an agent can watch arrive,
/// where a summary at close is evidence that may never come.
struct NetworkWebSocketPayload {
    /// The upgrade flow's id, so frames join their `network.request` (status 101).
    let requestId: String
    let url: String
    let host: String
    /// Zero-based position in the frame sequence Loom recorded for this socket.
    let frameIndex: Int
    /// `clientToServer` | `serverToClient`.
    let direction: String
    /// `text` | `binary` | `ping` | `pong` | `close` | `continuation`.
    let kind: String
    /// False for a fragment continued by later `continuation` frames.
    let isFinal: Bool
    let bytes: Int
    let frameMillis: Int64
    /// UTF-8 preview of a text frame, capped — the whole payload is under the event's
    /// `refs` when it did not fit. Nil for a binary frame, which has no text reading.
    var textPreview: String?
    var textPreviewTruncated: Bool?
    /// Set on the one event that announces recording stopped. `framesRecorded` is what
    /// this session did emit; `framesNotRecorded` is what Loom's own cap dropped, when
    /// it said so. A socket that keeps talking past this point is still open — the
    /// silence that follows is Reticle's cap, not the socket going quiet, and that
    /// distinction is the whole reason this event exists.
    var capReached: Bool?
    var framesRecorded: Int?
    var framesNotRecorded: Int?

    var json: [String: JSONValue] {
        var values: [String: JSONValue] = [
            "requestId": .string(requestId),
            "url": .string(url),
            "host": .string(host),
            "frameIndex": .number(Double(frameIndex)),
            "direction": .string(direction),
            "kind": .string(kind),
            "isFinal": .bool(isFinal),
            "bytes": .number(Double(bytes)),
            "frameMillis": .number(Double(frameMillis))
        ]
        if let textPreview { values["textPreview"] = .string(textPreview) }
        if let textPreviewTruncated { values["textPreviewTruncated"] = .bool(textPreviewTruncated) }
        if let capReached { values["capReached"] = .bool(capReached) }
        if let framesRecorded { values["framesRecorded"] = .number(Double(framesRecorded)) }
        if let framesNotRecorded { values["framesNotRecorded"] = .number(Double(framesNotRecorded)) }
        return values
    }
}

struct NetworkEventFactory {
    let target: String?

    /// Creates a daemon event request for one normalized network observation.
    func event(_ type: NetworkEventType, payload: NetworkEventPayload, refs: [String: String] = [:]) -> EventPostRequest {
        EventPostRequest(
            target: target,
            source: "proxy",
            type: type.rawValue,
            payload: payload.json,
            refs: refs
        )
    }

    /// Creates a daemon event request for a capture-fidelity advisory.
    func event(advisory payload: NetworkAdvisoryPayload) -> EventPostRequest {
        EventPostRequest(
            target: target,
            source: "proxy",
            type: NetworkEventType.advisory.rawValue,
            payload: payload.json,
            refs: [:]
        )
    }

    /// Creates a daemon event request for one observed WebSocket frame.
    func event(webSocket payload: NetworkWebSocketPayload, refs: [String: String] = [:]) -> EventPostRequest {
        EventPostRequest(
            target: target,
            source: "proxy",
            type: NetworkEventType.webSocket.rawValue,
            payload: payload.json,
            refs: refs
        )
    }
}
