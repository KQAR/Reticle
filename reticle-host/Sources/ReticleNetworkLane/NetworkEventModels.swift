import Foundation
import ReticleHostShared

/// Event kinds emitted by the host proxy into the daemon event bus.
enum NetworkEventType: String {
    case request = "network.request"
    case response = "network.response"
    case error = "network.error"
    /// A replayed exchange plus its diff against the original flow.
    case replay = "network.replay"
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
            values["diff"] = .object(d)
        }
        return values
    }
}

/// Builds event requests for network proxy observations.
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
}
