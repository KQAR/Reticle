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

    static func refused(_ reason: String) -> HelperRpcResponse {
        HelperRpcResponse(ok: false, result: nil, error: reason)
    }
}

struct ReticleHelperRoutes: Sendable {
    let helper: HelperCalling?
    /// Where the synchronous `helper.call` blocks. The call holds the helper's
    /// `callLock` for up to its full timeout, and the Swift cooperative pool is
    /// only about as wide as the core count — a handful of concurrent broker
    /// requests against a wedged helper parked there would freeze EVERY other
    /// route (events, SSE, panel, rules) for the duration. A dedicated serial
    /// queue matches the lock's one-at-a-time reality and keeps the pool free.
    private let callQueue = DispatchQueue(label: "reticle.helper-broker.call")

    func register(on router: Router<BasicRequestContext>) {
        guard let helper else { return }
        router.post("helper/rpc") { request, _ -> Response in
            let body = try await badRequestOnDecode {
                try await decode(HelperRpcRequest.self, from: request)
            }
            // The broker forwards a caller-supplied method name into the helper
            // process, so it is the one place a string can bypass the typed
            // `HostBackend` surface everything else goes through. Gate it on the
            // wire contract: an unknown method is refused by name rather than
            // handed to the helper to reject (or, worse, to answer).
            guard HelperMethod.isKnown(body.method) else {
                return try jsonResponse(
                    HelperRpcResponse.refused(
                        "unknown helper method '\(body.method)'. The broker forwards only the "
                            + "reticle-protocol/helper-rpc.md methods: "
                            + HelperMethod.allCases.map(\.rawValue).sorted().joined(separator: ", ")
                    ),
                    status: .badRequest
                )
            }
            let params = body.params?.mapValues(\.anyValue) ?? [:]
            let response = await withCheckedContinuation { continuation in
                callQueue.async {
                    do {
                        continuation.resume(returning: HelperRpcResponse.success(try helper.call(body.method, params)))
                    } catch {
                        continuation.resume(returning: HelperRpcResponse.failure(error))
                    }
                }
            }
            return try jsonResponse(response)
        }
    }
}
