import Dispatch
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

    /// Sends a proxied HTTP request upstream and returns the response body.
    func data(for head: HTTPRequestHead, url: URL, body: Data) throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = head.method.rawValue
        for header in head.headers {
            guard !Self.hopByHopHeaders.contains(header.name.lowercased()) else { continue }
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        request.httpBody = body.isEmpty ? nil : body
        let (data, response) = try blockingData(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NetworkForwardingError.nonHTTPResponse
        }
        return (data, http)
    }

    private func blockingData(for request: URLRequest) throws -> (Data, URLResponse) {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BlockingURLResult()
        session.dataTask(with: request) { data, response, error in
            if let error {
                box.set(.failure(error))
            } else if let data, let response {
                box.set(.success((data, response)))
            } else {
                box.set(.failure(NetworkForwardingError.nonHTTPResponse))
            }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return try box.get()
    }

    private static let hopByHopHeaders = Set([
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "proxy-connection",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade"
    ])
}

enum NetworkForwardingError: Error {
    case nonHTTPResponse
}

private final class BlockingURLResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<(Data, URLResponse), Error>?

    func set(_ result: Result<(Data, URLResponse), Error>) {
        lock.withLock { self.result = result }
    }

    func get() throws -> (Data, URLResponse) {
        try lock.withLock { try result!.get() }
    }
}
