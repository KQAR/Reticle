import Foundation
import Network

/// Localhost REST/SSE server backing `reticle serve`.
public final class ReticleHttpServer: @unchecked Sendable {
    private let store: EventStore
    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.reticle.serve.http")
    private let ready = DispatchSemaphore(value: 0)
    private let sse = SseEncoder()
    private let traceIngest = ActionTraceIngest()

    public private(set) var port: Int

    /// Creates a daemon HTTP server on `port`; pass 0 for an ephemeral port.
    public init(store: EventStore, port: Int) throws {
        self.store = store
        let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) ?? 0
        listener = try NWListener(using: .tcp, on: nwPort)
        self.port = port
    }

    /// Starts listening and waits until Network.framework reports readiness.
    public func start() throws {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let raw = self?.listener.port?.rawValue {
                    self?.port = Int(raw)
                }
                self?.ready.signal()
            case .failed:
                self?.ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 2)
    }

    /// Stops accepting new connections.
    public func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if error != nil || done {
                connection.cancel()
                return
            }
            var next = accumulated
            if let data { next.append(data) }
            if self.hasCompleteRequest(next) {
                self.route(data: next, connection: connection)
            } else {
                self.receiveRequest(on: connection, accumulated: next)
            }
        }
    }

    private func hasCompleteRequest(_ data: Data) -> Bool {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        let headerText = String(data: headerData, encoding: .utf8) ?? ""
        let lengthLine = headerText
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
        let length = lengthLine.flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        return data.count >= headerEnd.upperBound + length
    }

    private func route(data: Data, connection: NWConnection) {
        do {
            let request = try HttpRequest(data: data)
            if request.method == "GET", request.path == "/events/stream" {
                try streamEvents(request: request, connection: connection)
                return
            }
            let response = try handle(request)
            send(response.data(), on: connection, close: true)
        } catch {
            let response = HttpResponse.text("error: \(error)", status: 400, reason: "Bad Request")
            send(response.data(), on: connection, close: true)
        }
    }

    private func handle(_ request: HttpRequest) throws -> HttpResponse {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return try .json(HealthResponse(ok: true, session: store.session, port: port, eventCount: store.eventCount))
        case ("GET", "/sessions"):
            let info = SessionInfo(id: store.session, path: store.sessionDirectory.path, eventCount: store.eventCount)
            return try .json(SessionsResponse(sessions: [info]))
        case ("GET", "/sessions/current/events"):
            return try .json(EventsResponse(events: store.events(since: request.query["since"])))
        case ("POST", "/sessions/current/events"):
            let body = try JSONDecoder().decode(EventPostRequest.self, from: request.body)
            return try .json(store.append(body), status: 201, reason: "Created")
        case ("POST", "/sessions/current/action-traces"):
            let body = try traceIngest.event(from: request.body)
            return try .json(store.append(body), status: 201, reason: "Created")
        default:
            return HttpResponse.text("not found", status: 404, reason: "Not Found")
        }
    }

    private func streamEvents(request: HttpRequest, connection: NWConnection) throws {
        send(sse.headers(), on: connection, close: false)
        for event in store.events(since: request.query["since"]) {
            send(try sse.encode(event), on: connection, close: false)
        }
        let token = store.subscribe { [weak self, weak connection] event in
            guard let self, let connection else { return }
            if let data = try? self.sse.encode(event) {
                self.send(data, on: connection, close: false)
            }
        }
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state {
                self?.store.unsubscribe(token)
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection, close: Bool) {
        let completion: NWConnection.SendCompletion = .contentProcessed { _ in
            if close { connection.cancel() }
        }
        connection.send(content: data, completion: completion)
    }
}
