import Foundation
import NIOHTTP1

/// Sink that receives a streamed upstream response: the head once, then zero or
/// more body chunks as they arrive off the wire, then a single terminal
/// `finish`. Implemented by the proxy exchange that forwards the response back
/// to the client. Every callback arrives on URLSession's serial delegate queue.
protocol UpstreamResponseSink: AnyObject, Sendable {
    func receive(response: HTTPURLResponse)
    func receive(bodyChunk: Data)
    func finish(error: Error?)
}

/// Performs upstream HTTP forwarding without using the host's system proxy,
/// streaming the response body chunk-by-chunk instead of buffering it whole.
final class NetworkURLForwarder: @unchecked Sendable {
    static let shared = NetworkURLForwarder()

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 30
        // The resource timeout caps a transfer's TOTAL duration and silently
        // overrides any longer per-request timeout, so keep it well above what
        // callers can configure; stalls are still cut by the per-request idle
        // timeout (request.timeoutInterval set in stream(for:)).
        configuration.timeoutIntervalForResource = 600
        // Streaming and redirect suppression live on a per-task delegate (macOS
        // 14+), so the session itself needs no delegate.
        session = URLSession(configuration: configuration)
    }

    /// Streams a proxied HTTP request upstream, delivering the response to `sink`
    /// as it arrives without blocking the proxy event loop.
    func stream(
        for head: HTTPRequestHead,
        url: URL,
        body: Data,
        timeout: TimeInterval,
        sink: UpstreamResponseSink
    ) -> NetworkForwardingTask {
        var request = URLRequest(url: url)
        request.httpMethod = head.method.rawValue
        request.timeoutInterval = timeout
        for header in head.headers {
            guard ProxyHopByHopHeaders.shouldForwardRequestHeader(header.name, in: head.headers) else { continue }
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        request.httpBody = body.isEmpty ? nil : body
        let delegate = StreamingTaskDelegate(sink: sink)
        let task = session.dataTask(with: request)
        task.delegate = delegate
        task.resume()
        return NetworkForwardingTask(task: task, delegate: delegate)
    }
}

/// Handle to an in-flight upstream stream. `suspend`/`resume` back-pressure the
/// upstream fetch when the client channel stops draining.
final class NetworkForwardingTask: @unchecked Sendable {
    private let task: URLSessionDataTask
    private let delegate: StreamingTaskDelegate

    init(task: URLSessionDataTask, delegate: StreamingTaskDelegate) {
        self.task = task
        self.delegate = delegate
    }

    func cancel() {
        task.cancel()
    }

    func suspend() {
        task.suspend()
    }

    func resume() {
        task.resume()
    }
}

enum NetworkForwardingError: Error {
    case nonHTTPResponse
}

/// Per-task URLSession delegate: forwards streamed head/body/completion to the
/// sink and cancels URLSession's automatic redirect following so 3xx responses
/// pass through to the client unchanged.
final class StreamingTaskDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let sink: UpstreamResponseSink

    init(sink: UpstreamResponseSink) {
        self.sink = sink
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            sink.finish(error: NetworkForwardingError.nonHTTPResponse)
            completionHandler(.cancel)
            return
        }
        sink.receive(response: http)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        sink.receive(bodyChunk: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        sink.finish(error: error)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
