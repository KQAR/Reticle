import Foundation
import Hummingbird
import NIOCore

/// Localhost REST/SSE server backing `reticle serve`.
public final class ReticleHttpServer: @unchecked Sendable {
    private let store: EventStore
    private let mockStore: NetworkMockStore?
    private let ready = DispatchSemaphore(value: 0)
    private let traceIngest = ActionTraceIngest()
    private let lock = NSLock()
    private var runTask: Task<Void, Error>?
    private var serverChannel: (any Channel)?
    private var startupError: Error?

    public private(set) var port: Int

    /// Creates a daemon HTTP server on `port`; pass 0 for an ephemeral port.
    public init(store: EventStore, port: Int, mockStore: NetworkMockStore? = nil) throws {
        self.store = store
        self.mockStore = mockStore
        self.port = port
    }

    /// Starts listening and waits until Hummingbird reports the server channel.
    public func start() throws {
        let router = buildRouter()
        let app = Application(
            router: router,
            configuration: .init(
                address: .hostname("127.0.0.1", port: port),
                serverName: "reticle-serve"
            ),
            onServerRunning: { [weak self] channel in
                guard let self else { return }
                self.lock.withLock {
                    self.serverChannel = channel
                    if let boundPort = channel.localAddress?.port {
                        self.port = boundPort
                    }
                }
                self.ready.signal()
            }
        )
        runTask = Task { [weak self] in
            do {
                try await app.runService(gracefulShutdownSignals: [])
            } catch {
                guard let self else { throw error }
                self.lock.withLock {
                    self.startupError = error
                }
                self.ready.signal()
                throw error
            }
        }
        switch ready.wait(timeout: .now() + 2) {
        case .success:
            if let error = lock.withLock({ startupError }) {
                throw error
            }
        case .timedOut:
            throw ReticleHttpServerError.startTimedOut
        }
    }

    /// Stops accepting new connections.
    public func stop() {
        lock.lock()
        let channel = serverChannel
        serverChannel = nil
        lock.unlock()
        if let channel {
            _ = channel.close()
        } else {
            runTask?.cancel()
        }
        runTask = nil
    }

    private func buildRouter() -> Router<BasicRequestContext> {
        let router = Router()
        router.get("panel") { _, _ -> Response in
            webPanelResponse()
        }
        router.get("health") { [self] _, _ -> Response in
            try jsonResponse(HealthResponse(ok: true, session: store.session, port: port, eventCount: store.eventCount))
        }
        router.get("sessions") { [self] _, _ -> Response in
            return try jsonResponse(SessionsResponse(sessions: store.sessionInfos()))
        }
        router.get("sessions/current/events") { [self] request, _ -> Response in
            try sessionEventsResponse(session: store.session, since: query(request, "since"))
        }
        router.get("sessions/:session/events") { [self] request, context -> Response in
            try sessionEventsResponse(session: try sessionParameter(context), since: query(request, "since"))
        }
        router.get("sessions/current/artifacts") { [self] request, _ -> Response in
            try artifactResponse(session: store.session, eventId: query(request, "event"), refName: query(request, "ref"))
        }
        router.get("sessions/:session/artifacts") { [self] request, context -> Response in
            try artifactResponse(
                session: try sessionParameter(context),
                eventId: query(request, "event"),
                refName: query(request, "ref")
            )
        }
        router.post("sessions/current/events") { [self] request, _ -> Response in
            let body = try await badRequestOnDecode {
                try await decode(EventPostRequest.self, from: request)
            }
            return try jsonResponse(store.append(body), status: .created)
        }
        router.post("sessions/current/action-traces") { [self] request, _ -> Response in
            let body = try await badRequestOnDecode {
                try await traceIngest.event(from: requestBodyData(request))
            }
            return try jsonResponse(store.append(body), status: .created)
        }
        router.get("sessions/current/mocks/rules") { [self] _, _ -> Response in
            try jsonResponse(NetworkMockRulesResponse(rules: try requireMockStore().listRules()))
        }
        router.post("sessions/current/mocks/rules") { [self] request, _ -> Response in
            let body = try await badRequestOnDecode {
                try await decode(NetworkMockRuleRequest.self, from: request)
            }
            return try mockResponse {
                try jsonResponse(try requireMockStore().upsertRule(body), status: .created)
            }
        }
        router.post("sessions/current/mocks/rules/:id/enable") { [self] _, context -> Response in
            try mockResponse {
                try jsonResponse(try requireMockStore().setRuleEnabled(id: try idParameter(context), enabled: true))
            }
        }
        router.post("sessions/current/mocks/rules/:id/disable") { [self] _, context -> Response in
            try mockResponse {
                try jsonResponse(try requireMockStore().setRuleEnabled(id: try idParameter(context), enabled: false))
            }
        }
        router.delete("sessions/current/mocks/rules/:id") { [self] _, context -> Response in
            try mockResponse {
                try requireMockStore().removeRule(id: try idParameter(context))
                return try jsonResponse(["removed": true])
            }
        }
        router.get("sessions/current/mocks/values") { [self] _, _ -> Response in
            try jsonResponse(NetworkMockValuesResponse(values: try requireMockStore().listValues()))
        }
        router.post("sessions/current/mocks/values") { [self] request, _ -> Response in
            let body = try await badRequestOnDecode {
                try await decode(NetworkMockValueRequest.self, from: request)
            }
            return try mockResponse {
                try jsonResponse(try requireMockStore().upsertValue(body), status: .created)
            }
        }
        router.delete("sessions/current/mocks/values/:id") { [self] _, context -> Response in
            try mockResponse {
                try requireMockStore().removeValue(id: try idParameter(context))
                return try jsonResponse(["removed": true])
            }
        }
        router.get("events/stream") { [self] request, _ -> Response in
            sseResponse(since: query(request, "since"))
        }
        return router
    }

    private func requireMockStore() throws -> NetworkMockStore {
        guard let mockStore else {
            throw HTTPError(.notFound, message: "mock store is not available")
        }
        return mockStore
    }

    private func sseResponse(since: String?) -> Response {
        Response(
            status: .ok,
            headers: [.contentType: "text/event-stream; charset=utf-8", .cacheControl: "no-cache"],
            body: .init { [store] writer in
                let encoder = SseEncoder()
                for event in store.events(since: since) {
                    try await writer.write(buffer(from: try encoder.encode(event)))
                }
                let stream = AsyncStream<Data> { continuation in
                    let token = store.subscribe { event in
                        if let data = try? encoder.encode(event) {
                            continuation.yield(data)
                        }
                    }
                    continuation.onTermination = { _ in
                        store.unsubscribe(token)
                    }
                }
                for await data in stream {
                    try await writer.write(buffer(from: data))
                }
                try await writer.finish(nil)
            }
        )
    }

    private func sessionEventsResponse(session id: String, since: String?) throws -> Response {
        do {
            return try jsonResponse(EventsResponse(events: store.historicalEvents(session: id, since: since)))
        } catch let error as EventStoreError {
            throw HTTPError(.notFound, message: error.description)
        }
    }

    private func artifactResponse(session id: String, eventId: String?, refName: String?) throws -> Response {
        guard let eventId, let refName, !eventId.isEmpty, !refName.isEmpty else {
            throw HTTPError(.badRequest, message: "artifact requests require event and ref")
        }
        let event: ReticleEventEnvelope?
        do {
            event = try store.historicalEvent(session: id, eventId: eventId)
        } catch let error as EventStoreError {
            throw HTTPError(.notFound, message: error.description)
        }
        guard let event else {
            throw HTTPError(.notFound, message: "event not found")
        }
        guard let path = event.refs[refName] else {
            throw HTTPError(.notFound, message: "artifact ref not found")
        }
        let url = URL(fileURLWithPath: path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            throw HTTPError(.notFound, message: "artifact file not found")
        }
        guard let fileType = attributes[.type] as? FileAttributeType, fileType == .typeRegular else {
            throw HTTPError(.notFound, message: "artifact is not a regular file")
        }
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount <= 25 * 1024 * 1024 else {
            throw HTTPError(.badRequest, message: "artifact is too large")
        }
        let data = try Data(contentsOf: url)
        return Response(
            status: .ok,
            headers: [.contentType: contentType(for: url)],
            body: .init(byteBuffer: buffer(from: data))
        )
    }
}

private func idParameter(_ context: BasicRequestContext) throws -> String {
    guard let id = context.parameters.get("id"), !id.isEmpty else {
        throw HTTPError(.badRequest, message: "id route parameter is required")
    }
    return id
}

private func mockResponse(_ operation: () throws -> Response) throws -> Response {
    do {
        return try operation()
    } catch let error as NetworkMockError {
        switch error {
        case .notFound:
            throw HTTPError(.notFound, message: error.description)
        case .invalid, .missingValue:
            throw HTTPError(.badRequest, message: error.description)
        }
    }
}

public enum ReticleHttpServerError: Error, CustomStringConvertible {
    case startTimedOut

    public var description: String {
        switch self {
        case .startTimedOut:
            "reticle serve did not report a listening socket within 2 seconds"
        }
    }
}

private func badRequestOnDecode<T>(_ operation: () async throws -> T) async throws -> T {
    do {
        return try await operation()
    } catch {
        throw HTTPError(.badRequest, message: "\(error)")
    }
}

private func decode<T: Decodable>(_ type: T.Type, from request: Request) async throws -> T {
    try JSONDecoder().decode(type, from: try await requestBodyData(request))
}

private func requestBodyData(_ request: Request) async throws -> Data {
    var request = request
    let body = try await request.collectBody(upTo: 2 * 1024 * 1024)
    return Data(body.readableBytesView)
}
