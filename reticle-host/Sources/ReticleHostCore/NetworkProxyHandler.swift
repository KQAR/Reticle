import Foundation
import NIOCore
import NIOHTTP1
import NIOSSL
import NIOPosix

/// Handles HTTP proxy requests and CONNECT tunnel setup.
final class NetworkProxyHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let store: EventStore
    private let bodyStore: NetworkBodyStore
    private let factory: NetworkEventFactory
    private let tlsPolicy: TlsInterceptionPolicy
    private let certificates: ProxyCertificateStore?
    private var head: HTTPRequestHead?
    private var body = Data()
    private var handlingTunnel = false

    init(
        store: EventStore,
        bodyStore: NetworkBodyStore,
        factory: NetworkEventFactory,
        tlsPolicy: TlsInterceptionPolicy,
        certificates: ProxyCertificateStore?
    ) {
        self.store = store
        self.bodyStore = bodyStore
        self.factory = factory
        self.tlsPolicy = tlsPolicy
        self.certificates = certificates
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
            guard !handlingTunnel else { return }
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
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
        context.close(promise: nil)
    }

    private func forwardHTTP(head: HTTPRequestHead, body: Data, context: ChannelHandlerContext) {
        let requestId = UUID().uuidString
        let start = millis()
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
        _ = try? store.append(factory.event(.request, payload: payload, refs: refs))
        do {
            let (responseData, response) = try NetworkURLForwarder.shared.data(for: head, url: target.url, body: body)
            var responseRefs = refs
            var responsePayload = payload
            responsePayload.endMillis = millis()
            responsePayload.status = response.statusCode
            responsePayload.responseHeaders = NetworkHeaders.response(response.allHeaderFields)
            if let stored = try? bodyStore.store(responseData, requestId: requestId, role: "response") {
                responseRefs[stored.refName] = stored.path
                responsePayload.responseBodyBytes = stored.bytes
                responsePayload.responseBodyTruncated = stored.truncated
            }
            _ = try? store.append(factory.event(.response, payload: responsePayload, refs: responseRefs))
            write(responseData, response: response, version: head.version, context: context)
        } catch {
            emitError(requestId: requestId, target: target, message: "\(error)", start: start)
            writeError(.badGateway, context: context)
        }
    }

    private func handleConnect(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        let requestId = UUID().uuidString
        let start = millis()
        guard let target = HTTPProxyTarget(connectTarget: head.uri) else {
            emitError(requestId: requestId, message: "invalid CONNECT target", start: start)
            writeError(.badRequest, context: context)
            return
        }
        let wantsMitm = tlsPolicy.allows(host: target.host)
        let sslContext = wantsMitm ? try? certificates?.serverContext(host: target.host) : nil
        let payload = target.payload(requestId: requestId, method: "CONNECT", start: start, tunnel: true, mitm: sslContext != nil)
        _ = try? store.append(factory.event(.request, payload: payload))
        if wantsMitm && sslContext == nil {
            var errorPayload = payload
            errorPayload.error = "MITM policy matched but certificate material was unavailable"
            errorPayload.endMillis = start
            _ = try? store.append(factory.event(.error, payload: errorPayload))
        }
        let serverChannel = context.channel
        ClientBootstrap(group: context.eventLoop)
            .connect(host: target.host, port: target.port)
            .whenComplete { result in
                switch result {
                case .success(let peer):
                    var done = payload
                    done.endMillis = self.millis()
                    done.status = 200
                    _ = try? self.store.append(self.factory.event(.response, payload: done))
                    if let sslContext {
                        self.startMITM(target: target, sslContext: sslContext, channel: serverChannel)
                        _ = peer.close()
                    } else {
                        self.startTunnel(peer: peer, channel: serverChannel)
                    }
                case .failure(let error):
                    self.emitError(requestId: requestId, target: target, message: "\(error)", start: start)
                    self.writeError(.badGateway, context: context)
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
                    factory: self.factory
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

    private func write(_ data: Data, response: HTTPURLResponse, version: HTTPVersion, context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String else { continue }
            headers.replaceOrAdd(name: name, value: "\(value)")
        }
        headers.replaceOrAdd(name: "Content-Length", value: "\(data.count)")
        let head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: response.statusCode), headers: headers)
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func writeError(_ status: HTTPResponseStatus, context: ChannelHandlerContext) {
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: HTTPHeaders([("Content-Length", "0")]))
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func emitError(requestId: String, target: HTTPProxyTarget? = nil, message: String, start: Int64) {
        var payload = target?.payload(requestId: requestId, method: "UNKNOWN", start: start, tunnel: false, mitm: false)
            ?? NetworkEventPayload(requestId: requestId, scheme: "unknown", method: "UNKNOWN", url: "", host: "", port: 0, path: "", startMillis: start, tunnel: false, mitm: false)
        payload.endMillis = millis()
        payload.error = message
        _ = try? store.append(factory.event(.error, payload: payload))
    }

    private func millis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
