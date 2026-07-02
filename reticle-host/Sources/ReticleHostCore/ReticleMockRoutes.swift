import Foundation
import Hummingbird

struct ReticleMockRoutes: Sendable {
    let mockStore: NetworkMockStore?

    func register(on router: Router<BasicRequestContext>) {
        router.get("sessions/current/mocks/export") { _, _ -> Response in
            try jsonResponse(try requireMockStore().exportPackage())
        }
        router.post("sessions/current/mocks/import") { request, _ -> Response in
            let body = try await badRequestOnDecode {
                try await decode(NetworkMockExport.self, from: request)
            }
            return try mockResponse {
                try requireMockStore().importPackage(body)
                return try jsonResponse(["imported": true], status: .created)
            }
        }
        router.post("sessions/current/mocks/clear") { _, _ -> Response in
            try mockResponse {
                try requireMockStore().clear()
                return try jsonResponse(["cleared": true])
            }
        }
        router.post("sessions/current/mocks/resolve") { request, _ -> Response in
            let body = try await badRequestOnDecode {
                try await decode(NetworkMockResolveRequest.self, from: request)
            }
            return try mockResponse {
                let result = try requireMockStore().resolve(resolveRequest(body))
                return try jsonResponse(NetworkMockResolveResponse(matched: result != nil, rule: result?.rule, value: result?.value))
            }
        }
        router.get("sessions/current/mocks/rules") { _, _ -> Response in
            try jsonResponse(NetworkMockRulesResponse(rules: try requireMockStore().listRules()))
        }
        router.post("sessions/current/mocks/rules") { request, _ -> Response in
            let body = try await badRequestOnDecode {
                try await decode(NetworkMockRuleRequest.self, from: request)
            }
            return try mockResponse {
                try jsonResponse(try requireMockStore().upsertRule(body), status: .created)
            }
        }
        router.post("sessions/current/mocks/rules/:id/enable") { _, context -> Response in
            try mockResponse {
                try jsonResponse(try requireMockStore().setRuleEnabled(id: try idParameter(context), enabled: true))
            }
        }
        router.post("sessions/current/mocks/rules/:id/disable") { _, context -> Response in
            try mockResponse {
                try jsonResponse(try requireMockStore().setRuleEnabled(id: try idParameter(context), enabled: false))
            }
        }
        router.delete("sessions/current/mocks/rules/:id") { _, context -> Response in
            try mockResponse {
                try requireMockStore().removeRule(id: try idParameter(context))
                return try jsonResponse(["removed": true])
            }
        }
        router.get("sessions/current/mocks/values") { _, _ -> Response in
            try jsonResponse(NetworkMockValuesResponse(values: try requireMockStore().listValues()))
        }
        router.post("sessions/current/mocks/values") { request, _ -> Response in
            let body = try await badRequestOnDecode {
                try await decode(NetworkMockValueRequest.self, from: request)
            }
            return try mockResponse {
                try jsonResponse(try requireMockStore().upsertValue(body), status: .created)
            }
        }
        router.delete("sessions/current/mocks/values/:id") { _, context -> Response in
            try mockResponse {
                try requireMockStore().removeValue(id: try idParameter(context))
                return try jsonResponse(["removed": true])
            }
        }
    }

    private func requireMockStore() throws -> NetworkMockStore {
        guard let mockStore else {
            throw HTTPError(.notFound, message: "mock store is not available")
        }
        return mockStore
    }

    private func idParameter(_ context: BasicRequestContext) throws -> String {
        guard let id = context.parameters.get("id"), !id.isEmpty else {
            throw HTTPError(.badRequest, message: "id route parameter is required")
        }
        return id
    }

    private func resolveRequest(_ request: NetworkMockResolveRequest) throws -> NetworkMockRequest {
        guard let components = URLComponents(string: request.url), components.scheme != nil else {
            throw NetworkMockError.invalid("url must be absolute")
        }
        return NetworkMockRequest(method: request.method, url: request.url, path: components.path.isEmpty ? "/" : components.path)
    }

    private func mockResponse(_ operation: () throws -> Response) throws -> Response {
        do {
            return try operation()
        } catch let error as NetworkMockError {
            switch error {
            case .notFound:
                throw HTTPError(.notFound, message: error.description)
            case .invalid, .missingValue:
                throw HTTPError(.badRequest, message: error.description)
            }
        }
    }
}
