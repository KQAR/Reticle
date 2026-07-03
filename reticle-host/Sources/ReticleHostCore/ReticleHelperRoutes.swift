import Foundation
import Hummingbird

struct HelperRpcRequest: Decodable, Sendable {
    let method: String
    let params: [String: JSONValue]?
}

struct HelperRpcResponse: Codable, Sendable {
    let ok: Bool
    let result: [String: JSONValue]?
    let error: String?

    static func success(_ result: [String: Any]) -> HelperRpcResponse {
        HelperRpcResponse(ok: true, result: result.mapValues(JSONValue.fromAny), error: nil)
    }

    static func failure(_ error: Error) -> HelperRpcResponse {
        HelperRpcResponse(ok: false, result: nil, error: "\(error)")
    }
}

struct ReticleHelperRoutes: Sendable {
    let helper: HelperCalling?

    func register(on router: Router<BasicRequestContext>) {
        guard let helper else { return }
        router.post("helper/rpc") { request, _ -> Response in
            let body = try await badRequestOnDecode {
                try await decode(HelperRpcRequest.self, from: request)
            }
            let params = body.params?.mapValues(\.anyValue) ?? [:]
            let response = await Task.detached {
                do {
                    return HelperRpcResponse.success(try helper.call(body.method, params))
                } catch {
                    return HelperRpcResponse.failure(error)
                }
            }.value
            return try jsonResponse(response)
        }
    }
}
