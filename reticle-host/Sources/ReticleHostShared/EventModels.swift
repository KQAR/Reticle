import Foundation

/// Common event envelope persisted by `reticle serve`.
public struct ReticleEventEnvelope: Codable, Equatable {
    /// Current envelope generation. Bumped only on a breaking envelope-shape
    /// change (a field renamed/removed/retyped) — per-payload versions like
    /// `traceVersion` are independent. See reticle-protocol/schema/event.schema.json.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
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
        refs: [String: String] = [:],
        schemaVersion: Int = ReticleEventEnvelope.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.ts = ts
        self.session = session
        self.target = target
        self.source = source
        self.type = type
        self.payload = payload
        self.refs = refs
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, ts, session, target, source, type, payload, refs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Legacy events.jsonl written before the marker existed decode as v1
        // rather than being skipped as corrupt — the field is additive.
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try c.decode(String.self, forKey: .id)
        ts = try c.decode(Int64.self, forKey: .ts)
        session = try c.decode(String.self, forKey: .session)
        target = try c.decodeIfPresent(String.self, forKey: .target)
        source = try c.decode(String.self, forKey: .source)
        type = try c.decode(String.self, forKey: .type)
        payload = try c.decodeIfPresent([String: JSONValue].self, forKey: .payload) ?? [:]
        refs = try c.decodeIfPresent([String: String].self, forKey: .refs) ?? [:]
    }
}

/// Incoming event body accepted by `POST /sessions/current/events`.
public struct EventPostRequest: Codable {
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

    public init(events: [ReticleEventEnvelope]) {
        self.events = events
    }
}

/// Health response for the local daemon.
public struct HealthResponse: Encodable {
    public let ok: Bool
    public let session: String
    public let port: Int
    public let eventCount: Int

    public init(ok: Bool, session: String, port: Int, eventCount: Int) {
        self.ok = ok
        self.session = session
        self.port = port
        self.eventCount = eventCount
    }
}

/// Single-session listing returned by `GET /sessions`.
public struct SessionInfo: Codable, Equatable {
    public let id: String
    public let path: String
    public let eventCount: Int
    public let actionTraceCount: Int
    public let updatedAtMillis: Int64?
    public let isCurrent: Bool

    public init(
        id: String,
        path: String,
        eventCount: Int,
        actionTraceCount: Int,
        updatedAtMillis: Int64?,
        isCurrent: Bool
    ) {
        self.id = id
        self.path = path
        self.eventCount = eventCount
        self.actionTraceCount = actionTraceCount
        self.updatedAtMillis = updatedAtMillis
        self.isCurrent = isCurrent
    }
}

/// Session list response for the daemon's REST API.
public struct SessionsResponse: Codable {
    public let sessions: [SessionInfo]

    public init(sessions: [SessionInfo]) {
        self.sessions = sessions
    }
}
