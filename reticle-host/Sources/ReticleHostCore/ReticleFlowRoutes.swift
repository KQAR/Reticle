import Foundation
import Hummingbird

/// Flow replay route. The capture lane that services replays is bound after the
/// server starts (once the proxy port is known), so the route reads it late through
/// a closure rather than capturing it at registration.
struct ReticleFlowRoutes: Sendable {
    let replayer: @Sendable () -> FlowReplaying?
    let querier: @Sendable () -> FlowQuerying?

    func register(on router: Router<BasicRequestContext>) {
        router.get("sessions/current/flows") { request, _ -> Response in
            guard let querier = querier() else {
                throw HTTPError(.notFound, message: "flow listing is unavailable; start serve with the capture proxy enabled")
            }
            let query = request.uri.queryParameters
            func string(_ name: String) -> String? {
                guard let value = query[name[...]].map(String.init), !value.isEmpty else { return nil }
                return value
            }
            func integer(_ name: String) throws -> Int? {
                guard let raw = string(name) else { return nil }
                guard let value = Int(raw) else {
                    throw HTTPError(.badRequest, message: "\(name) must be an integer, got \(raw)")
                }
                return value
            }
            // `status=404` is the common case; the bounds are there for ranges.
            let exact = try integer("status")
            let filter = NetworkFlowFilter(
                host: string("host"),
                methods: string("method").map { $0.split(separator: ",").map(String.init) },
                urlContains: string("urlContains"),
                statusMin: try exact ?? integer("statusMin"),
                statusMax: try exact ?? integer("statusMax"),
                onlyErrors: string("onlyErrors") == "true",
                since: (try integer("sinceMillis")).map { Date(timeIntervalSince1970: Double($0) / 1000) },
                limit: (try integer("limit")) ?? 50
            )
            do {
                return try jsonResponse(try querier.listFlows(matching: filter))
            } catch let error as NetworkReplayError {
                throw HTTPError(.badGateway, message: error.description)
            }
        }

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
