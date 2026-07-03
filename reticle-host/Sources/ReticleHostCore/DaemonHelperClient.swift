import Foundation

/// Helper RPC client that forwards one-shot command calls through a live daemon.
final class DaemonHelperClient: HelperCalling, @unchecked Sendable {
    private let discovery: DaemonDiscovery
    private let timeout: TimeInterval
    private let serial: String?

    init(discovery: DaemonDiscovery = DaemonDiscovery(), timeout: TimeInterval = 15.0, serial: String? = nil) {
        self.discovery = discovery
        self.timeout = timeout
        self.serial = serial
    }

    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        guard let info = discovery.readLive() else {
            throw HelperError("reticle serve is not running; start it with --helper-broker or remove --use-daemon")
        }
        guard let url = URL(string: "http://127.0.0.1:\(info.port)/helper/rpc") else {
            throw HelperError("invalid daemon helper URL")
        }

        var params = params
        if let serial, params["serial"] == nil {
            params["serial"] = serial
        }

        let body: [String: Any] = ["method": method, "params": params]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let sema = DispatchSemaphore(value: 0)
        let box = DaemonHelperResultBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sema.signal() }
            if let error {
                box.set(.failure(error))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status), let data else {
                box.set(.failure(HelperError("daemon helper rejected RPC with HTTP \(status)")))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(HelperRpcResponse.self, from: data)
                guard decoded.ok else {
                    throw HelperError(decoded.error ?? "<no error message>")
                }
                box.set(.success(decoded.result?.mapValues(\.anyValue) ?? [:]))
            } catch {
                box.set(.failure(error))
            }
        }
        task.resume()
        if sema.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw HelperError("daemon helper RPC timed out")
        }
        return try box.value.get()
    }
}

private final class DaemonHelperResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<[String: Any], Error> = .success([:])

    var value: Result<[String: Any], Error> {
        lock.lock()
        defer { lock.unlock() }
        return result
    }

    func set(_ value: Result<[String: Any], Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }
}
