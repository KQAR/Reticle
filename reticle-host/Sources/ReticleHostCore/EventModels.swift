import Foundation

/// Common event envelope persisted by `reticle serve`.
public struct ReticleEventEnvelope: Codable, Equatable {
    public let id: String
    public let ts: Int64
    public let session: String
    public let target: String?
    public let source: String
    public let type: String
    public let payload: [String: JSONValue]
    public let refs: [String: String]

    /// Creates a daemon-stamped event envelope.
    public init(
        id: String,
        ts: Int64,
        session: String,
        target: String?,
        source: String,
        type: String,
        payload: [String: JSONValue] = [:],
        refs: [String: String] = [:]
    ) {
        self.id = id
        self.ts = ts
        self.session = session
        self.target = target
        self.source = source
        self.type = type
        self.payload = payload
        self.refs = refs
    }
}

/// Incoming event body accepted by `POST /sessions/current/events`.
public struct EventPostRequest: Decodable {
    public let target: String?
    public let source: String
    public let type: String
    public let payload: [String: JSONValue]
    public let refs: [String: String]

    /// Creates a post body with optional payload and refs.
    public init(
        target: String? = nil,
        source: String,
        type: String,
        payload: [String: JSONValue] = [:],
        refs: [String: String] = [:]
    ) {
        self.target = target
        self.source = source
        self.type = type
        self.payload = payload
        self.refs = refs
    }

    private enum CodingKeys: String, CodingKey {
        case target, source, type, payload, refs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        source = try container.decode(String.self, forKey: .source)
        type = try container.decode(String.self, forKey: .type)
        payload = try container.decodeIfPresent([String: JSONValue].self, forKey: .payload) ?? [:]
        refs = try container.decodeIfPresent([String: String].self, forKey: .refs) ?? [:]
    }
}

/// Event history response returned by REST endpoints.
public struct EventsResponse: Codable {
    public let events: [ReticleEventEnvelope]
}

/// Health response for the local daemon.
public struct HealthResponse: Encodable {
    public let ok: Bool
    public let session: String
    public let port: Int
    public let eventCount: Int
}

/// Single-session listing returned by `GET /sessions`.
public struct SessionInfo: Encodable {
    public let id: String
    public let path: String
    public let eventCount: Int
}

/// Session list response for the daemon's REST API.
public struct SessionsResponse: Encodable {
    public let sessions: [SessionInfo]
}
