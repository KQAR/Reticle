import Foundation
import NIOHTTP1

/// Performs upstream HTTP forwarding without using the host's system proxy.
final class NetworkURLForwarder: @unchecked Sendable {
    static let shared = NetworkURLForwarder()

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration)
    }

    /// Sends a proxied HTTP request upstream without blocking the proxy event loop.
    func data(
        for head: HTTPRequestHead,
        url: URL,
        body: Data,
        timeout: TimeInterval,
        completion: @escaping @Sendable (Result<(Data, HTTPURLResponse), Error>) -> Void
    ) -> NetworkForwardingTask {
        var request = URLRequest(url: url)
        request.httpMethod = head.method.rawValue
        request.timeoutInterval = timeout
        for header in head.headers {
            guard ProxyHopByHopHeaders.shouldForwardRequestHeader(header.name, in: head.headers) else { continue }
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        request.httpBody = body.isEmpty ? nil : body
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
            } else if let data, let response {
                guard let http = response as? HTTPURLResponse else {
                    completion(.failure(NetworkForwardingError.nonHTTPResponse))
                    return
                }
                completion(.success((data, http)))
            } else {
                completion(.failure(NetworkForwardingError.nonHTTPResponse))
            }
        }
        task.resume()
        return NetworkForwardingTask(task: task)
    }
}

final class NetworkForwardingTask: @unchecked Sendable {
    private let task: URLSessionDataTask

    init(task: URLSessionDataTask) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

enum NetworkForwardingError: Error {
    case nonHTTPResponse
}
