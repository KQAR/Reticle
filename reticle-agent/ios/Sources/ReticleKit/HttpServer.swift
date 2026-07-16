import Foundation
import Network

/// A tiny loopback HTTP/1.1 server built on Network.framework — the iOS analogue
/// of the Android `ReticleServer` (a hand-rolled `ServerSocket`). It binds
/// 127.0.0.1 only, reads one request per connection, dispatches to the `Router`,
/// writes the response, and closes (`Connection: close`). No third-party
/// dependency, no auth (loopback-only, dev-machine-trusted — same model as the
/// Android agent).
final class HttpServer: @unchecked Sendable {
    private let router: Router
    private let queue = DispatchQueue(label: "dev.reticle.server", qos: .userInitiated)
    private var listener: NWListener?
    private(set) var isRunning = false

    // Guards against a runaway body; matches the Android agent's 4 MiB cap.
    private let maxBodyBytes = 4 * 1024 * 1024

    init(router: Router) {
        self.router = router
    }

    /// Bind and start accepting. Returns the actually-bound port. Throws if the
    /// port can't be bound (e.g. already in use).
    func start(host: String, port: Int) throws -> Int {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ServerError.badPort(port)
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind loopback-only via requiredLocalEndpoint. Do NOT also pass `on:` — a
        // port in both the endpoint and `on:` conflicts and fails bind with EINVAL.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: nwPort
        )
        let listener = try NWListener(using: params)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        let startBox = ErrorBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startBox.set(error)
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.start(queue: queue)

        // Wait briefly for the listener to reach .ready or .failed.
        if ready.wait(timeout: .now() + 3.0) == .timedOut {
            listener.cancel()
            throw ServerError.timeout
        }
        if let startError = startBox.get() {
            listener.cancel()
            throw startError
        }
        isRunning = true
        return Int(listener.port?.rawValue ?? UInt16(port))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveRequest(conn, buffer: Data())
    }

    private func receiveRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let parsed = HttpRequest.tryParse(buffer, maxBody: self.maxBodyBytes) {
                switch parsed {
                case .needMore:
                    if isComplete || error != nil {
                        self.close(conn)
                    } else {
                        self.receiveRequest(conn, buffer: buffer)
                    }
                case .tooLarge:
                    self.respond(conn, HttpResponse.text(413, "request body too large"))
                case .badRequest(let msg):
                    self.respond(conn, HttpResponse.text(400, msg))
                case .ok(let request):
                    let response = self.router.route(request)
                    self.respond(conn, response)
                }
            } else if isComplete || error != nil {
                self.close(conn)
            } else {
                self.receiveRequest(conn, buffer: buffer)
            }
        }
    }

    private func respond(_ conn: NWConnection, _ response: HttpResponse) {
        conn.send(content: response.serialize(), completion: .contentProcessed { [weak self] _ in
            self?.close(conn)
        })
    }

    private func close(_ conn: NWConnection) {
        conn.cancel()
    }

    /// Thread-safe holder so the `@Sendable` state-update closure can report a
    /// startup failure back to `start()` without capturing a mutable var.
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var error: Error?
        func set(_ e: Error) { lock.lock(); error = e; lock.unlock() }
        func get() -> Error? { lock.lock(); defer { lock.unlock() }; return error }
    }

    enum ServerError: Error, CustomStringConvertible {
        case badPort(Int)
        case timeout
        var description: String {
            switch self {
            case .badPort(let p): return "invalid port \(p)"
            case .timeout: return "listener did not become ready"
            }
        }
    }
}
