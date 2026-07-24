import Foundation
import Hummingbird

/// Flow replay route. The capture lane that services replays is bound after the
/// server starts (once the proxy port is known), so the route reads it late through
/// a closure rather than capturing it at registration.
struct ReticleFlowRoutes: Sendable {
    let replayer: @Sendable () -> FlowReplaying?

    func register(on router: Router<BasicRequestContext>) {
        router.post("sessions/current/flows/:id/replay") { request, context -> Response in
            guard let id = context.parameters.get("id"), !id.isEmpty else {
                throw HTTPError(.badRequest, message: "flow id route parameter is required")
            }
            guard let replayer = replayer() else {
                throw HTTPError(.notFound, message: "flow replay is unavailable; start serve with the capture proxy enabled")
            }
            // An empty body means "keep everything" — replay the flow verbatim.
            let overrides = try await badRequestOnDecode { () -> NetworkReplayRequest in
                let data = try await requestBodyData(request)
                guard !data.isEmpty else { return NetworkReplayRequest() }
                return try JSONDecoder().decode(NetworkReplayRequest.self, from: data)
            }
            do {
                return try jsonResponse(try replayer.replay(requestId: id, request: overrides))
            } catch let error as NetworkReplayError {
                switch error {
                case .notFound: throw HTTPError(.notFound, message: error.description)
                case .invalid: throw HTTPError(.badRequest, message: error.description)
                case .failed: throw HTTPError(.badGateway, message: error.description)
                }
            }
        }
    }
}
