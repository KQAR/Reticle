import Foundation
import Hummingbird
import NIOCore

func query(_ request: Request, _ key: String) -> String? {
    request.uri.queryParameters[Substring(key)].map(String.init)
}

func sessionParameter(_ context: BasicRequestContext) throws -> String {
    guard let session = context.parameters.get("session"), !session.isEmpty else {
        throw HTTPError(.badRequest, message: "session route parameter is required")
    }
    return session
}

func jsonResponse<T: Encodable>(
    _ value: T,
    status: HTTPResponse.Status = .ok
) throws -> Response {
    Response(
        status: status,
        headers: [.contentType: "application/json; charset=utf-8"],
        body: .init(byteBuffer: buffer(from: try JSONEncoder().encode(value)))
    )
}

func buffer(from data: Data) -> ByteBuffer {
    var buffer = ByteBufferAllocator().buffer(capacity: data.count)
    buffer.writeBytes(data)
    return buffer
}

func contentType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "json":
        "application/json; charset=utf-8"
    case "png":
        "image/png"
    case "jpg", "jpeg":
        "image/jpeg"
    case "webp":
        "image/webp"
    default:
        "application/octet-stream"
    }
}
