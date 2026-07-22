import Foundation
import ReticleHostShared
import NIOCore
import NIOHTTP1

/// Handles HTTP requests decoded after a CONNECT TLS interception.
final class MitmHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let target: HTTPProxyTarget
    private let store: any NetworkEventSink
    private let bodyStore: NetworkBodyStore
    private let factory: NetworkEventFactory
    private let mockStore: NetworkMockStore?
    private let upstreamTimeoutSeconds: TimeInterval
    private let maxRequestBodyBytes: Int
    private var head: HTTPRequestHead?
    private var body = Data()
    private var upstreamTask: NetworkForwardingTask?
    private var upstreamPaused = false

    init(
        target: HTTPProxyTarget,
        store: any NetworkEventSink,
        bodyStore: NetworkBodyStore,
        factory: NetworkEventFactory,
        mockStore: NetworkMockStore?,
        upstreamTimeoutSeconds: TimeInterval,
        maxRequestBodyBytes: Int
    ) {
        self.target = target
        self.store = store
        self.bodyStore = bodyStore
        self.factory = factory
        self.mockStore = mockStore
        self.upstreamTimeoutSeconds = upstreamTimeoutSeconds
        self.maxRequestBodyBytes = maxRequestBodyBytes
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body.removeAll(keepingCapacity: true)
        case .body(var buffer):
            // `head == nil` after an oversized-body reject: drain silently.
            guard head != nil else { return }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                if body.count + bytes.count > maxRequestBodyBytes {
                    rejectOversizedRequestBody(context: context)
                    return
                }
                body.append(contentsOf: bytes)
            }
        case .end:
            guard let head else { return }
            forward(head: head, body: body, context: context)
            self.head = nil
            body.removeAll(keepingCapacity: false)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        upstreamTask?.cancel()
        upstreamTask = nil
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        upstreamTask?.cancel()
        upstreamTask = nil
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        // Back-pressure the upstream fetch when the client stops draining so a
        // slow client can't make us buffer an unbounded response in memory.
        guard let upstreamTask else {
            context.fireChannelWritabilityChanged()
            return
        }
        if context.channel.isWritable {
            if upstreamPaused { upstreamPaused = false; upstreamTask.resume() }
        } else {
            if !upstreamPaused { upstreamPaused = true; upstreamTask.suspend() }
        }
        context.fireChannelWritabilityChanged()
    }

    private func forward(head: HTTPRequestHead, body: Data, context: ChannelHandlerContext) {
        let requestId = UUID().uuidString
        let start = currentMillis()
        guard let url = upstreamURL(for: head) else {
            var errorPayload = NetworkEventPayload(
                requestId: requestId,
                scheme: "https",
                method: head.method.rawValue,
                url: head.uri,
                host: target.host,
                port: target.port,
                path: "/",
                startMillis: start,
                tunnel: false,
                mitm: true
            )
            errorPayload.endMillis = currentMillis()
            errorPayload.error = "invalid intercepted request URI"
            store.emit(factory.event(.error, payload: errorPayload))
            writeError(context: context)
            return
        }
        var refs: [String: String] = [:]
        var payload = NetworkEventPayload(
            requestId: requestId,
            scheme: "https",
            method: head.method.rawValue,
            url: url.absoluteString,
            host: target.host,
            port: target.port,
            path: url.path.isEmpty ? "/" : url.path,
            startMillis: start,
            tunnel: false,
            mitm: true
        )
        payload.requestHeaders = NetworkHeaders.request(head.headers)
        if let stored = try? bodyStore.store(body, requestId: requestId, role: "request") {
            refs[stored.refName] = stored.path
            payload.requestBodyBytes = stored.bytes
            payload.requestBodyTruncated = stored.truncated
        }
        store.emit(factory.event(.request, payload: payload, refs: refs))
        do {
            if let mock = try mockStore?.resolve(NetworkMockRequest(method: head.method.rawValue, url: url.absoluteString, path: payload.path, host: target.host)) {
                writeMock(mock, payload: payload, refs: refs, version: head.version, context: context)
                return
            }
        } catch let error as NetworkMockError {
            emitMockError(error, payload: payload, refs: refs)
            writeError(context: context)
            return
        } catch {
            payload.endMillis = currentMillis()
            payload.error = "\(error)"
            store.emit(factory.event(.error, payload: payload, refs: refs))
            writeError(context: context)
            return
        }
        pauseReads(context: context)
        let executor = ChannelContextExecutor(context)
        let exchange = ProxyStreamingExchange(
            executor: executor,
            store: store,
            bodyStore: bodyStore,
            factory: factory,
            clientVersion: head.version,
            requestMethod: head.method.rawValue,
            requestId: requestId,
            requestPayload: payload,
            requestRefs: refs,
            onFinish: { [weak self] in
                self?.upstreamTask = nil
                self?.upstreamPaused = false
            }
        )
        upstreamTask = NetworkURLForwarder.shared.stream(
            for: head,
            url: url,
            body: body,
            timeout: upstreamTimeoutSeconds,
            sink: exchange
        )
    }

    private func upstreamURL(for head: HTTPRequestHead) -> URL? {
        if let absolute = URL(string: head.uri), absolute.scheme != nil {
            return absolute
        }
        // head.uri comes off an intercepted TLS connection and may contain
        // characters that make URL(string:) fail — never force-unwrap it.
        return URL(string: "https://\(target.host):\(target.port)\(head.uri)")
    }

    private func writeMock(
        _ mock: NetworkMockResult,
        payload: NetworkEventPayload,
        refs: [String: String],
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) {
        var responsePayload = payload
        responsePayload.endMillis = currentMillis()
        responsePayload.status = mock.value.status
        responsePayload.responseHeaders = mock.value.headers
        responsePayload.mocked = true
        responsePayload.mockRuleId = mock.rule.id
        responsePayload.mockValueId = mock.value.id
        var responseRefs = refs
        if let stored = try? bodyStore.store(mock.body, requestId: payload.requestId, role: "response") {
            responseRefs[stored.refName] = stored.path
            responsePayload.responseBodyBytes = stored.bytes
            responsePayload.responseBodyTruncated = stored.truncated
        }
        store.emit(factory.event(.response, payload: responsePayload, refs: responseRefs))
        write(status: mock.value.status, headers: mock.value.headers, contentType: mock.value.contentType, data: mock.body, version: version, context: context)
    }

    private func write(status: Int, headers: [String: String], contentType: String, data: Data, version: HTTPVersion, context: ChannelHandlerContext) {
        var responseHeaders = HTTPHeaders()
        var hasContentType = false
        for (name, value) in headers {
            if name.lowercased() == "content-type" { hasContentType = true }
            responseHeaders.replaceOrAdd(name: name, value: value)
        }
        if !hasContentType {
            responseHeaders.replaceOrAdd(name: "Content-Type", value: contentType)
        }
        responseHeaders.replaceOrAdd(name: "Content-Length", value: "\(data.count)")
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.write(wrapOutboundOut(.head(.init(version: version, status: .init(statusCode: status), headers: responseHeaders))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func writeError(context: ChannelHandlerContext, status: HTTPResponseStatus = .badGateway, closeAfter: Bool = false) {
        var headers = HTTPHeaders([("Content-Length", "0")])
        if closeAfter { headers.replaceOrAdd(name: "Connection", value: "close") }
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if closeAfter {
            let promise = context.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenComplete { [channel = context.channel] _ in
                channel.close(promise: nil)
            }
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: promise)
        } else {
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    /// Same safety valve as the plaintext handler: past the cap, emit a
    /// `network.error` event, answer 413, and close (mid-body, keep-alive
    /// framing cannot be resynchronized).
    private func rejectOversizedRequestBody(context: ChannelHandlerContext) {
        guard let head else { return }
        let requestId = UUID().uuidString
        let start = currentMillis()
        var payload = NetworkEventPayload(
            requestId: requestId,
            scheme: "https",
            method: head.method.rawValue,
            url: upstreamURL(for: head)?.absoluteString ?? head.uri,
            host: target.host,
            port: target.port,
            path: upstreamURL(for: head)?.path ?? "/",
            startMillis: start,
            tunnel: false,
            mitm: true
        )
        payload.requestHeaders = NetworkHeaders.request(head.headers)
        payload.endMillis = currentMillis()
        payload.error = "request body exceeded the \(maxRequestBodyBytes)-byte in-memory buffering limit; rejected with 413"
        store.emit(factory.event(.error, payload: payload))
        writeError(context: context, status: .payloadTooLarge, closeAfter: true)
        self.head = nil
        body.removeAll(keepingCapacity: false)
    }

    private func pauseReads(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
    }

    private func emitMockError(_ error: NetworkMockError, payload: NetworkEventPayload, refs: [String: String]) {
        var errorPayload = payload
        errorPayload.endMillis = currentMillis()
        errorPayload.error = error.description
        if case .missingValue(let ruleId, let valueId) = error {
            errorPayload.mocked = true
            errorPayload.mockRuleId = ruleId
            errorPayload.mockValueId = valueId
        }
        store.emit(factory.event(.error, payload: errorPayload, refs: refs))
    }
}
