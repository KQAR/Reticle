import Foundation
import NIOCore
import NIOHTTP1

/// Handles HTTP requests decoded after a CONNECT TLS interception.
final class MitmHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let target: HTTPProxyTarget
    private let store: EventStore
    private let bodyStore: NetworkBodyStore
    private let factory: NetworkEventFactory
    private let mockStore: NetworkMockStore?
    private var head: HTTPRequestHead?
    private var body = Data()

    init(target: HTTPProxyTarget, store: EventStore, bodyStore: NetworkBodyStore, factory: NetworkEventFactory, mockStore: NetworkMockStore?) {
        self.target = target
        self.store = store
        self.bodyStore = bodyStore
        self.factory = factory
        self.mockStore = mockStore
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body.removeAll(keepingCapacity: true)
        case .body(var buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                body.append(contentsOf: bytes)
            }
        case .end:
            guard let head else { return }
            forward(head: head, body: body, context: context)
            self.head = nil
            body.removeAll(keepingCapacity: false)
        }
    }

    private func forward(head: HTTPRequestHead, body: Data, context: ChannelHandlerContext) {
        let requestId = UUID().uuidString
        let start = Int64(Date().timeIntervalSince1970 * 1000)
        let url = upstreamURL(for: head)
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
        _ = try? store.append(factory.event(.request, payload: payload, refs: refs))
        do {
            if let mock = try mockStore?.resolve(NetworkMockRequest(method: head.method.rawValue, url: url.absoluteString, path: payload.path)) {
                writeMock(mock, payload: payload, refs: refs, version: head.version, context: context)
                return
            }
        } catch let error as NetworkMockError {
            emitMockError(error, payload: payload, refs: refs)
            writeError(context: context)
            return
        } catch {
            payload.endMillis = Int64(Date().timeIntervalSince1970 * 1000)
            payload.error = "\(error)"
            _ = try? store.append(factory.event(.error, payload: payload, refs: refs))
            writeError(context: context)
            return
        }
        do {
            let (data, response) = try NetworkURLForwarder.shared.data(for: head, url: url, body: body)
            var responsePayload = payload
            responsePayload.endMillis = Int64(Date().timeIntervalSince1970 * 1000)
            responsePayload.status = response.statusCode
            responsePayload.responseHeaders = NetworkHeaders.response(response.allHeaderFields)
            var responseRefs = refs
            if let stored = try? bodyStore.store(data, requestId: requestId, role: "response") {
                responseRefs[stored.refName] = stored.path
                responsePayload.responseBodyBytes = stored.bytes
                responsePayload.responseBodyTruncated = stored.truncated
            }
            _ = try? store.append(factory.event(.response, payload: responsePayload, refs: responseRefs))
            write(data, response: response, version: head.version, context: context)
        } catch {
            payload.endMillis = Int64(Date().timeIntervalSince1970 * 1000)
            payload.error = "\(error)"
            _ = try? store.append(factory.event(.error, payload: payload, refs: refs))
            writeError(context: context)
        }
    }

    private func upstreamURL(for head: HTTPRequestHead) -> URL {
        if let absolute = URL(string: head.uri), absolute.scheme != nil {
            return absolute
        }
        return URL(string: "https://\(target.host):\(target.port)\(head.uri)")!
    }

    private func writeMock(
        _ mock: NetworkMockResult,
        payload: NetworkEventPayload,
        refs: [String: String],
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) {
        var responsePayload = payload
        responsePayload.endMillis = Int64(Date().timeIntervalSince1970 * 1000)
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
        _ = try? store.append(factory.event(.response, payload: responsePayload, refs: responseRefs))
        write(status: mock.value.status, headers: mock.value.headers, contentType: mock.value.contentType, data: mock.body, version: version, context: context)
    }

    private func write(_ data: Data, response: HTTPURLResponse, version: HTTPVersion, context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String else { continue }
            headers.replaceOrAdd(name: name, value: "\(value)")
        }
        headers.replaceOrAdd(name: "Content-Length", value: "\(data.count)")
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.write(wrapOutboundOut(.head(.init(version: version, status: .init(statusCode: response.statusCode), headers: headers))), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
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

    private func writeError(context: ChannelHandlerContext) {
        let head = HTTPResponseHead(version: .http1_1, status: .badGateway, headers: HTTPHeaders([("Content-Length", "0")]))
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func emitMockError(_ error: NetworkMockError, payload: NetworkEventPayload, refs: [String: String]) {
        var errorPayload = payload
        errorPayload.endMillis = Int64(Date().timeIntervalSince1970 * 1000)
        errorPayload.error = error.description
        if case .missingValue(let ruleId, let valueId) = error {
            errorPayload.mocked = true
            errorPayload.mockRuleId = ruleId
            errorPayload.mockValueId = valueId
        }
        _ = try? store.append(factory.event(.error, payload: errorPayload, refs: refs))
    }
}
