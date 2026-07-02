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
                for event in store.events(since: since) {
                    try await writer.write(buffer(from: try encoder.encode(event)))
                }
                let stream = AsyncStream<Data> { continuation in
                    let token = store.subscribe { event in
                        if let data = try? encoder.encode(event) {
                            continuation.yield(data)
                        }
                    }
                    continuation.onTermination = { _ in
                        store.unsubscribe(token)
                    }
                }
                for await data in stream {
                    try await writer.write(buffer(from: data))
                }
                try await writer.finish(nil)
            }
        )
    }
}
