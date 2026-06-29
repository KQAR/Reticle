import Foundation

/// Encodes Reticle events as WHATWG server-sent event frames.
public struct SseEncoder {
    private let encoder = JSONEncoder()

    /// Creates an SSE frame with `id`, named `event`, and one JSON `data` line.
    public func encode(_ event: ReticleEventEnvelope) throws -> Data {
        let json = try encoder.encode(event)
        let data = String(data: json, encoding: .utf8) ?? "{}"
        return Data("id: \(event.id)\nevent: \(event.type)\ndata: \(data)\n\n".utf8)
    }

    /// Initial bytes for a successful SSE response.
    public func headers() -> Data {
        Data(
            """
            HTTP/1.1 200 OK\r
            Content-Type: text/event-stream; charset=utf-8\r
            Cache-Control: no-cache\r
            Connection: keep-alive\r
            \r

            """.utf8
        )
    }
}
