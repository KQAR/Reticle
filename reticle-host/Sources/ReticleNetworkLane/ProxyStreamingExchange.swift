import Foundation
import ReticleHostShared
import NIOCore
import NIOHTTP1

/// Streams one upstream HTTP response back to the proxy client as it arrives
/// while capturing a bounded body prefix as a session artifact and emitting the
/// terminal `network.response` / `network.error` event. Shared by the plaintext
/// and MITM proxy handlers so both get identical streaming, framing, and
/// evidence behavior.
///
/// Callbacks from `UpstreamResponseSink` run on URLSession's serial delegate
/// queue, so the accumulation fields below need no locking; every channel write
/// hops to the event loop through `executor`, which preserves submission order.
final class ProxyStreamingExchange: UpstreamResponseSink, @unchecked Sendable {
    /// How the response body is framed back to the client.
    enum Framing: Equatable {
        /// Identity body of known size: forwarded verbatim under Content-Length.
        case contentLength
        /// Unknown or decoded length: forwarded under Transfer-Encoding: chunked.
        case chunked
        /// 204 / 304 / HEAD: head only, no body is forwarded.
        case none
    }

    private let executor: ChannelContextExecutor
    private let store: any NetworkEventSink
    private let bodyStore: NetworkBodyStore
    private let factory: NetworkEventFactory
    private let clientVersion: HTTPVersion
    private let requestMethod: String
    private let requestId: String
    private let limitBytes: Int
    private let onFinish: @Sendable () -> Void

    private var payload: NetworkEventPayload
    private var refs: [String: String]

    private var framing: Framing = .chunked
    private var prefix = Data()
    private var totalBytes = 0
    private var wroteHead = false
    private var finished = false

    init(
        executor: ChannelContextExecutor,
        store: any NetworkEventSink,
        bodyStore: NetworkBodyStore,
        factory: NetworkEventFactory,
        clientVersion: HTTPVersion,
        requestMethod: String,
        requestId: String,
        requestPayload: NetworkEventPayload,
        requestRefs: [String: String],
        onFinish: @escaping @Sendable () -> Void
    ) {
        self.executor = executor
        self.store = store
        self.bodyStore = bodyStore
        self.factory = factory
        self.clientVersion = clientVersion
        self.requestMethod = requestMethod
        self.requestId = requestId
        self.limitBytes = bodyStore.limitBytes
        self.onFinish = onFinish
        self.payload = requestPayload
        self.refs = requestRefs
    }

    func receive(response: HTTPURLResponse) {
        let (headers, framing, status) = forwardedHead(from: response)
        self.framing = framing
        payload.status = status
        payload.responseHeaders = NetworkHeaders.response(response.allHeaderFields)
        wroteHead = true
        executor.execute { context in
            let head = HTTPResponseHead(
                version: self.clientVersion,
                status: HTTPResponseStatus(statusCode: status),
                headers: headers
            )
            context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
            if framing == .none {
                context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
            } else {
                context.flush()
            }
        }
    }

    func receive(bodyChunk: Data) {
        guard !bodyChunk.isEmpty, framing != .none else { return }
        totalBytes += bodyChunk.count
        if prefix.count < limitBytes {
            prefix.append(bodyChunk.prefix(limitBytes - prefix.count))
        }
        executor.execute { context in
            var buffer = context.channel.allocator.buffer(capacity: bodyChunk.count)
            buffer.writeBytes(bodyChunk)
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
        }
    }

    func finish(error: Error?) {
        // The delegate may report both a synthetic failure (e.g. non-HTTP
        // response) and a later cancellation; the serial queue lets a plain flag
        // drop the second call.
        guard !finished else { return }
        finished = true

        if let error {
            emitTerminalEvent(.error, message: "\(error)")
            if wroteHead {
                // Mid-body failure: the head/framing is already committed, so we
                // can only sever the connection and let the client see a
                // truncated response.
                executor.execute { context in
                    context.close(promise: nil)
                    self.onFinish()
                }
            } else {
                // Nothing sent yet: a clean 502 keeps the keep-alive connection
                // usable for the next request.
                executor.execute { context in
                    let head = HTTPResponseHead(
                        version: self.clientVersion,
                        status: .badGateway,
                        headers: HTTPHeaders([("Content-Length", "0")])
                    )
                    context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
                    context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
                    self.resumeReads(context)
                    self.onFinish()
                }
            }
            return
        }

        emitTerminalEvent(.response, message: nil)
        executor.execute { context in
            if self.framing != .none {
                context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
            }
            self.resumeReads(context)
            self.onFinish()
        }
    }

    private func emitTerminalEvent(_ type: NetworkEventType, message: String?) {
        payload.endMillis = currentMillis()
        payload.error = message
        if let stored = try? bodyStore.store(prefix: prefix, totalBytes: totalBytes, requestId: requestId, role: "response") {
            refs[stored.refName] = stored.path
            payload.responseBodyBytes = stored.bytes
            payload.responseBodyTruncated = stored.truncated
        }
        store.emit(factory.event(type, payload: payload, refs: refs))
    }

    /// Computes the client-facing head. Sensitive values in the event payload are
    /// redacted separately; the wire head keeps the raw upstream headers minus
    /// hop-by-hop names and the framing headers we re-derive here.
    private func forwardedHead(from response: HTTPURLResponse) -> (HTTPHeaders, Framing, Int) {
        let status = response.statusCode
        let bodyForbidden = status == 204 || status == 304 || requestMethod == "HEAD"

        var contentEncoding: String?
        var contentLength: String?
        for (key, value) in response.allHeaderFields {
            guard let name = (key as? String)?.lowercased() else { continue }
            if name == "content-encoding" { contentEncoding = "\(value)" }
            if name == "content-length" { contentLength = "\(value)" }
        }

        var headers = HTTPHeaders()
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String else { continue }
            guard ProxyHopByHopHeaders.shouldForwardResponseHeader(name, in: response.allHeaderFields) else { continue }
            let lower = name.lowercased()
            // Content-Length and Content-Encoding are re-derived below: URLSession
            // hands us a decoded body, so forwarding the upstream framing would
            // make the client decode twice or mis-frame the stream.
            if lower == "content-length" || lower == "content-encoding" { continue }
            headers.replaceOrAdd(name: name, value: "\(value)")
        }

        if bodyForbidden {
            if let contentLength {
                headers.replaceOrAdd(name: "Content-Length", value: contentLength)
            }
            return (headers, .none, status)
        }
        // An identity body with a declared length is byte-exact, so preserve
        // Content-Length and stream under it (keeps small responses cheap and
        // avoids chunk overhead). Anything decoded or of unknown length streams
        // chunked because the final size isn't known when the head is written.
        if contentEncoding == nil, let contentLength {
            headers.replaceOrAdd(name: "Content-Length", value: contentLength)
            return (headers, .contentLength, status)
        }
        headers.replaceOrAdd(name: "Transfer-Encoding", value: "chunked")
        return (headers, .chunked, status)
    }

    private func resumeReads(_ context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.autoRead, value: true)
        if context.channel.isActive {
            context.channel.read()
        }
    }
}
