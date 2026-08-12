import Foundation
import Network

/// A minimal HTTP/1.1 server for the runner to be driven through.
///
/// Hand-rolled rather than pulled in, for two reasons: a UI-test bundle is an
/// awkward place to host a dependency, and the surface needed here is tiny — a few
/// routes, one request per connection, no keep-alive, no chunked bodies. Every
/// response closes the connection, which is what the host's `URLSession` calls
/// expect anyway.
///
/// WebDriverAgent solves the same problem with CocoaHTTPServer; this is the same
/// idea at 1% of the size because Reticle's system channel is deliberately narrow.
final class RunnerHTTPServer {

    struct Request {
        var method: String
        var path: String
        /// Query parameters, already split out of `path`.
        var query: [String: String]
        var body: Data
    }

    struct Response {
        var status: Int
        var contentType: String
        var body: Data

        static func json(_ data: Data, status: Int = 200) -> Response {
            Response(status: status, contentType: "application/json", body: data)
        }

        static func png(_ data: Data) -> Response {
            Response(status: 200, contentType: "image/png", body: data)
        }

        /// An error the CALLER can act on. The runner refuses with a reason in the
        /// body rather than an empty status, because the host surfaces that body —
        /// a bare 4xx would strand whoever is driving.
        static func failure(_ status: Int, _ message: String) -> Response {
            let payload = ["error": message]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            return Response(status: status, contentType: "application/json", body: data)
        }
    }

    typealias Handler = (Request) -> Response

    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var routes: [String: Handler] = [:]
    private let queue = DispatchQueue(label: "dev.reticle.runner.http")

    /// Set when a caller asks the runner to leave. The never-ending test method
    /// watches this to return, which is the only clean way out of a run loop.
    private(set) var shutdownRequested = false

    init(port: Int) {
        self.port = NWEndpoint.Port(rawValue: UInt16(port))!
    }

    /// Register a handler. Key is `"<METHOD> <path>"`, e.g. `"GET /health"`.
    func route(_ key: String, _ handler: @escaping Handler) {
        routes[key] = handler
    }

    func requestShutdown() {
        shutdownRequested = true
    }

    func start() throws {
        let params = NWParameters.tcp
        // Loopback only. The device's loopback reaches the host through a USB
        // tunnel (iproxy), so binding wider would expose the driver to the network
        // for no gain.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let chunk { accumulated.append(chunk) }

            if error != nil {
                connection.cancel()
                return
            }

            // Keep reading until the headers are in and the declared body arrived.
            if let request = Self.parse(accumulated) {
                let response = self.handle(request)
                self.send(response, on: connection)
                return
            }

            if isComplete {
                self.send(.failure(400, "malformed request"), on: connection)
                return
            }
            self.receive(connection, buffer: accumulated)
        }
    }

    private func handle(_ request: Request) -> Response {
        guard let handler = routes["\(request.method) \(request.path)"] else {
            return .failure(404, "no such route: \(request.method) \(request.path)")
        }
        // Handlers run on the MAIN thread, not on the network queue.
        //
        // XCUIElement queries must be made from the test's own thread; issuing one
        // from a background queue kills the whole test — measured: the runner
        // vanished on the first `/system/overlay` request, and the host saw only
        // "The network connection was lost", which says nothing about the cause.
        //
        // This is safe because the never-ending test method is parked in a run loop
        // on the main thread, so it drains main-queue work while it waits.
        return DispatchQueue.main.sync { handler(request) }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(response.body)
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Parsing

    /// Returns nil while the request is still incomplete, so the caller keeps
    /// reading. Only `Content-Length` bodies are supported — the host never sends
    /// anything else.
    static func parse(_ data: Data) -> Request? {
        guard let headerEnd = range(of: "\r\n\r\n", in: data) else { return nil }
        let headerData = data[data.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])

        var contentLength = 0
        for line in lines {
            let pieces = line.split(separator: ":", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            if pieces[0].lowercased() == "content-length" {
                contentLength = Int(pieces[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStart = headerEnd.upperBound
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= contentLength else { return nil }
        let body = Data(data[bodyStart..<data.index(bodyStart, offsetBy: contentLength)])

        let (path, query) = splitTarget(target)
        return Request(method: method, path: path, query: query, body: body)
    }

    static func splitTarget(_ target: String) -> (path: String, query: [String: String]) {
        guard let q = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[target.startIndex..<q])
        let rest = target[target.index(after: q)...]
        var query: [String: String] = [:]
        for pair in rest.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let key = kv.first else { continue }
            let value = kv.count > 1 ? String(kv[1]) : ""
            query[String(key)] = value.replacingOccurrences(of: "%20", with: " ")
        }
        return (path, query)
    }

    static func range(of needle: String, in data: Data) -> Range<Data.Index>? {
        let pattern = Data(needle.utf8)
        guard data.count >= pattern.count else { return nil }
        return data.range(of: pattern)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 422: return "Unprocessable Entity"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }
}
