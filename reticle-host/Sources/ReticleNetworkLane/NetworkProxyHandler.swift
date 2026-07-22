import Foundation
import ReticleHostShared
import NIOCore
import NIOHTTP1
import NIOSSL
import NIOPosix

/// Handles HTTP proxy requests and CONNECT tunnel setup.
final class NetworkProxyHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let store: any NetworkEventSink
    private let bodyStore: NetworkBodyStore
    private let factory: NetworkEventFactory
    private let tlsPolicy: TlsInterceptionPolicy
    private let certificates: ProxyCertificateStore?
    private let mockStore: NetworkMockStore?
    private let upstreamTimeoutSeconds: TimeInterval
    private let maxRequestBodyBytes: Int
    private var head: HTTPRequestHead?
    private var body = Data()
    private var handlingTunnel = false
    private var upstreamTask: NetworkForwardingTask?
    private var upstreamPaused = false

    init(
        store: any NetworkEventSink,
        bodyStore: NetworkBodyStore,
        factory: NetworkEventFactory,
        tlsPolicy: TlsInterceptionPolicy,
        certificates: ProxyCertificateStore?,
        mockStore: NetworkMockStore?,
        upstreamTimeoutSeconds: TimeInterval,
        maxRequestBodyBytes: Int
    ) {
        self.store = store
        self.bodyStore = bodyStore
        self.factory = factory
        self.tlsPolicy = tlsPolicy
        self.certificates = certificates
        self.mockStore = mockStore
        self.upstreamTimeoutSeconds = upstreamTimeoutSeconds
        self.maxRequestBodyBytes = maxRequestBodyBytes
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            if head.method == .CONNECT {
                handlingTunnel = true
                handleConnect(head, context: context)
            } else {
                self.head = head
                body.removeAll(keepingCapacity: true)
            }
        case .body(var buffer):
            // `head == nil` after an oversized-body reject: drain silently.
            guard !handlingTunnel, head != nil else { return }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                if body.count + bytes.count > maxRequestBodyBytes {
                    rejectOversizedRequestBody(context: context)
                    return
                }
                body.append(contentsOf: bytes)
            }
        case .end:
            guard !handlingTunnel, let head else { return }
            forwardHTTP(head: head, body: body, context: context)
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

    private func forwardHTTP(head: HTTPRequestHead, body: Data, context: ChannelHandlerContext) {
        let requestId = UUID().uuidString
        let start = currentMillis()
        guard let target = HTTPProxyTarget(head: head, defaultScheme: "http") else {
            emitError(requestId: requestId, message: "invalid proxy request target", start: start)
            writeError(.badRequest, context: context)
            return
        }
        var refs: [String: String] = [:]
        var payload = target.payload(requestId: requestId, method: head.method.rawValue, start: start, tunnel: false, mitm: false)
        payload.requestHeaders = NetworkHeaders.request(head.headers)
        if let stored = try? bodyStore.store(body, requestId: requestId, role: "request") {
            refs[stored.refName] = stored.path
            payload.requestBodyBytes = stored.bytes
            payload.requestBodyTruncated = stored.truncated
        }
        store.emit(factory.event(.request, payload: payload, refs: refs))
        do {
            if let mock = try mockStore?.resolve(NetworkMockRequest(method: head.method.rawValue, url: target.url.absoluteString, path: target.path, host: target.host)) {
                writeMock(mock, payload: payload, refs: refs, version: head.version, context: context)
                return
            }
        } catch let error as NetworkMockError {
            emitMockError(error, payload: payload, refs: refs)
            writeError(.badGateway, context: context)
            return
        } catch {
            emitError(base: payload, refs: refs, message: "\(error)")
            writeError(.badGateway, context: context)
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
            url: target.url,
            body: body,
            timeout: upstreamTimeoutSeconds,
            sink: exchange
        )
    }

    private func handleConnect(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        let requestId = UUID().uuidString
        let start = currentMillis()
        guard let target = HTTPProxyTarget(connectTarget: head.uri) else {
            emitError(requestId: requestId, message: "invalid CONNECT target", start: start)
            // handlingTunnel is already set, so this handler would never route
            // another request on this connection — close instead of wedging it.
            writeError(.badRequest, context: context, closeAfter: true)
            return
        }
        let wantsMitm = tlsPolicy.allows(host: target.host)
        let sslContext = wantsMitm ? try? certificates?.serverContext(host: target.host) : nil
        let payload = target.payload(requestId: requestId, method: "CONNECT", start: start, tunnel: true, mitm: sslContext != nil)
        store.emit(factory.event(.request, payload: payload))
        if wantsMitm && sslContext == nil {
            var errorPayload = payload
            errorPayload.error = "MITM policy matched but certificate material was unavailable"
            errorPayload.endMillis = start
            store.emit(factory.event(.error, payload: errorPayload))
        }
        let serverChannel = context.channel
        ClientBootstrap(group: context.eventLoop)
            .connect(host: target.host, port: target.port)
            .whenComplete { result in
                switch result {
                case .success(let peer):
                    var done = payload
                    done.endMillis = currentMillis()
                    done.status = 200
                    self.store.emit(self.factory.event(.response, payload: done))
                    if let sslContext {
                        self.startMITM(target: target, sslContext: sslContext, channel: serverChannel)
                        _ = peer.close()
                    } else {
                        self.startTunnel(peer: peer, channel: serverChannel)
                    }
                case .failure(let error):
                    self.emitError(requestId: requestId, target: target, message: "\(error)", start: start)
                    // Same wedge as above: after a failed CONNECT the handler
                    // ignores all further reads, so a keep-alive client would
                    // hang forever on this connection.
                    self.writeError(.badGateway, context: context, closeAfter: true)
                }
            }
    }

    private func startTunnel(peer: Channel, channel: Channel) {
        channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
            channel.pipeline.removeHandler(name: "proxy-http-decoder").flatMap {
                channel.pipeline.removeHandler(name: "proxy-http-encoder")
            }.flatMap {
                channel.pipeline.removeHandler(self)
            }.flatMap {
                peer.pipeline.addHandler(ByteForwardingHandler(peer: channel))
            }.flatMap {
                channel.pipeline.addHandler(ByteForwardingHandler(peer: peer))
            }.flatMap {
                self.writeConnectEstablishedRaw(channel)
            }.flatMap {
                channel.setOption(ChannelOptions.autoRead, value: true)
            }
        }.whenComplete { result in
            switch result {
            case .success:
                channel.read()
            case .failure:
                _ = channel.close()
                _ = peer.close()
            }
        }
    }

    private func startMITM(target: HTTPProxyTarget, sslContext: NIOSSLContext, channel: Channel) {
        channel.setOption(ChannelOptions.autoRead, value: false).flatMap {
            channel.pipeline.removeHandler(name: "proxy-http-decoder").flatMap {
                channel.pipeline.removeHandler(name: "proxy-http-encoder")
            }.flatMap {
                channel.pipeline.removeHandler(self)
            }.flatMap {
                self.writeConnectEstablishedRaw(channel)
            }.flatMap {
                channel.pipeline.addHandler(NIOSSLServerHandler(context: sslContext))
            }.flatMap {
                channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder()))
            }.flatMap {
                channel.pipeline.addHandler(HTTPResponseEncoder())
            }.flatMap {
                channel.pipeline.addHandler(MitmHTTPHandler(
                    target: target,
                    store: self.store,
                    bodyStore: self.bodyStore,
                    factory: self.factory,
                    mockStore: self.mockStore,
                    upstreamTimeoutSeconds: self.upstreamTimeoutSeconds,
                    maxRequestBodyBytes: self.maxRequestBodyBytes
                ))
            }.flatMap {
                channel.setOption(ChannelOptions.autoRead, value: true)
            }
        }.whenComplete { result in
            switch result {
            case .success:
                channel.read()
            case .failure:
                _ = channel.close()
            }
        }
    }

    private func writeConnectEstablishedRaw(_ channel: Channel) -> EventLoopFuture<Void> {
        var buffer = channel.allocator.buffer(capacity: 64)
        buffer.writeString("HTTP/1.1 200 Connection Established\r\nProxy-Agent: reticle\r\n\r\n")
        return channel.writeAndFlush(buffer)
    }

    private func writeMock(
        _ mock: NetworkMockResult,
        payload: NetworkEventPayload,
        refs: [String: String],
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) {
        var responseRefs = refs
        var responsePayload = payload
        responsePayload.endMillis = currentMillis()
        responsePayload.status = mock.value.status
        responsePayload.responseHeaders = mock.value.headers
        responsePayload.mocked = true
        responsePayload.mockRuleId = mock.rule.id
        responsePayload.mockValueId = mock.value.id
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
        let head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: status), headers: responseHeaders)
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func writeError(_ status: HTTPResponseStatus, context: ChannelHandlerContext, closeAfter: Bool = false) {
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

    private func pauseReads(context: ChannelHandlerContext) {
        _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
    }

    /// The upstream forward needs the whole request body in memory today, so an
    /// unbounded upload would balloon the daemon. Past the cap: emit a
    /// `network.error` event, answer 413, and close (the connection is
    /// mid-body, so keep-alive framing cannot be resynchronized).
    private func rejectOversizedRequestBody(context: ChannelHandlerContext) {
        guard let head else { return }
        let requestId = UUID().uuidString
        let start = currentMillis()
        let message = "request body exceeded the \(maxRequestBodyBytes)-byte in-memory buffering limit; rejected with 413"
        if let target = HTTPProxyTarget(head: head, defaultScheme: "http") {
            var payload = target.payload(requestId: requestId, method: head.method.rawValue, start: start, tunnel: false, mitm: false)
            payload.requestHeaders = NetworkHeaders.request(head.headers)
            emitError(base: payload, message: message)
        } else {
            emitError(requestId: requestId, message: message, start: start)
        }
        writeError(.payloadTooLarge, context: context, closeAfter: true)
        self.head = nil
        body.removeAll(keepingCapacity: false)
    }

    private func emitError(requestId: String, target: HTTPProxyTarget? = nil, message: String, start: Int64) {
        let payload = target?.payload(requestId: requestId, method: "UNKNOWN", start: start, tunnel: false, mitm: false)
            ?? NetworkEventPayload(requestId: requestId, scheme: "unknown", method: "UNKNOWN", url: "", host: "", port: 0, path: "", startMillis: start, tunnel: false, mitm: false)
        emitError(base: payload, message: message)
    }

    /// Emits a `network.error` event carrying everything already known about
    /// the request (method, headers, body refs) instead of a bare skeleton.
    private func emitError(base: NetworkEventPayload, refs: [String: String] = [:], message: String) {
        var payload = base
        payload.endMillis = currentMillis()
        payload.error = message
        store.emit(factory.event(.error, payload: payload, refs: refs))
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
