import Foundation
import Hummingbird

struct ReticleStreamRoutes: Sendable {
    let store: EventStore

    func register(on router: Router<BasicRequestContext>) {
        router.get("panel") { _, _ -> Response in
            webPanelResponse()
        }
        router.get("events/stream") { request, _ -> Response in
            sseResponse(since: query(request, "since"))
        }
    }

    private func sseResponse(since: String?) -> Response {
        Response(
            status: .ok,
            headers: [.contentType: "text/event-stream; charset=utf-8", .cacheControl: "no-cache"],
            body: .init { writer in
                let encoder = SseEncoder()
                // Subscribe BEFORE replaying history: the subscribe closure runs
                // synchronously here, so any event appended during the replay is
                // buffered on the stream rather than lost in the gap between
                // replay and subscription. Events already covered by the replay
                // are de-duplicated by id below.
                // Yield an (id, encoded) pair — both Sendable — encoding inside the
                // subscriber closure as the original did, so the whole envelope
                // isn't sent across the concurrency boundary.
                let stream = AsyncStream<(String, Data)> { continuation in
                    let token = store.subscribe { event in
                        if let data = try? encoder.encode(event) {
                            continuation.yield((event.id, data))
                        }
                    }
                    continuation.onTermination = { _ in
                        store.unsubscribe(token)
                    }
                }
                // Event ids are fixed-width, monotonically increasing strings, so
                // lexicographic comparison tracks append order.
                var lastWritten: String? = since
                for event in store.events(since: since) {
                    try await writer.write(buffer(from: try encoder.encode(event)))
                    lastWritten = event.id
                }
                for await (id, data) in stream {
                    if let lastWritten, id <= lastWritten { continue }
                    lastWritten = id
                    try await writer.write(buffer(from: data))
                }
                try await writer.finish(nil)
            }
        )
    }
}
