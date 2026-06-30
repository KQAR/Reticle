import Foundation
import Hummingbird
import NIOCore

/// Localhost REST/SSE server backing `reticle serve`.
public final class ReticleHttpServer: @unchecked Sendable {
    private let store: EventStore
    private let ready = DispatchSemaphore(value: 0)
    private let traceIngest = ActionTraceIngest()
    private let lock = NSLock()
    private var runTask: Task<Void, Error>?
    private var serverChannel: (any Channel)?
    private var startupError: Error?

    public private(set) var port: Int

    /// Creates a daemon HTTP server on `port`; pass 0 for an ephemeral port.
    public init(store: EventStore, port: Int) throws {
        self.store = store
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
            let info = SessionInfo(id: store.session, path: store.sessionDirectory.path, eventCount: store.eventCount)
            return try jsonResponse(SessionsResponse(sessions: [info]))
        }
        router.get("sessions/current/events") { [self] request, _ -> Response in
            try jsonResponse(EventsResponse(events: store.events(since: query(request, "since"))))
        }
        router.get("sessions/current/artifacts") { [self] request, _ -> Response in
            try artifactResponse(eventId: query(request, "event"), refName: query(request, "ref"))
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
        router.get("events/stream") { [self] request, _ -> Response in
            sseResponse(since: query(request, "since"))
        }
        return router
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

    private func artifactResponse(eventId: String?, refName: String?) throws -> Response {
        guard let eventId, let refName, !eventId.isEmpty, !refName.isEmpty else {
            throw HTTPError(.badRequest, message: "artifact requests require event and ref")
        }
        guard let event = store.event(id: eventId) else {
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

public enum ReticleHttpServerError: Error, CustomStringConvertible {
    case startTimedOut

    public var description: String {
        switch self {
        case .startTimedOut:
            "reticle serve did not report a listening socket within 2 seconds"
        }
    }
}

private func query(_ request: Request, _ key: String) -> String? {
    request.uri.queryParameters[Substring(key)].map(String.init)
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

private func jsonResponse<T: Encodable>(
    _ value: T,
    status: HTTPResponse.Status = .ok
) throws -> Response {
    Response(
        status: status,
        headers: [.contentType: "application/json; charset=utf-8"],
        body: .init(byteBuffer: buffer(from: try JSONEncoder().encode(value)))
    )
}

private func buffer(from data: Data) -> ByteBuffer {
    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
    buffer.writeBytes(data)
    return buffer
}

private func contentType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "json":
        "application/json; charset=utf-8"
    case "png":
        "image/png"
    case "jpg", "jpeg":
        "image/jpeg"
    case "webp":
        "image/webp"
    default:
        "application/octet-stream"
    }
}
