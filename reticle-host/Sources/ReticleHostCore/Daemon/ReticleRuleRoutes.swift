import Foundation
import Hummingbird

struct ReticleRuleRoutes: Sendable {
    let ruleStore: NetworkRuleStore?

    func register(on router: Router<BasicRequestContext>) {
        router.get("sessions/current/rules/export") { _, _ -> Response in
            try jsonResponse(try requireRuleStore().exportPackage())
        }
        router.post("sessions/current/rules/import") { request, _ -> Response in
            let body = try await badRequestOnDecode {
                try await decode(NetworkRuleExport.self, from: request)
            }
            return try ruleResponse {
                try requireRuleStore().importPackage(body)
                return try jsonResponse(["imported": true], status: .created)
            }
        }
        router.post("sessions/current/rules/clear") { _, _ -> Response in
            try ruleResponse {
                try requireRuleStore().clear()
                return try jsonResponse(["cleared": true])
            }
        }
        router.post("sessions/current/rules/resolve") { request, _ -> Response in
            let body = try await badRequestOnDecode {
                try await decode(NetworkRuleResolveRequest.self, from: request)
            }
            return try ruleResponse {
                let result = try requireRuleStore().resolve(resolveRequest(body))
                return try jsonResponse(NetworkRuleResolveResponse(matched: result != nil, rule: result?.rule, value: result?.value))
            }
        }
        // Value sub-resource is registered before the `:id` rule routes so the static
        // `values` segment is never captured as a rule id.
        router.get("sessions/current/rules/values") { _, _ -> Response in
            try jsonResponse(NetworkMockValuesResponse(values: try requireRuleStore().listValues()))
        }
        router.post("sessions/current/rules/values") { request, _ -> Response in
            let body = try await badRequestOnDecode {
                try await decode(NetworkMockValueRequest.self, from: request)
            }
            return try ruleResponse {
                try jsonResponse(try requireRuleStore().upsertValue(body), status: .created)
            }
        }
        router.delete("sessions/current/rules/values/:id") { _, context -> Response in
            try ruleResponse {
                try requireRuleStore().removeValue(id: try idParameter(context))
                return try jsonResponse(["removed": true])
            }
        }
        router.get("sessions/current/rules") { _, _ -> Response in
            try jsonResponse(NetworkRulesResponse(rules: try requireRuleStore().listRules()))
        }
        router.post("sessions/current/rules") { request, _ -> Response in
            let body = try await badRequestOnDecode {
                try await decode(NetworkRuleRequest.self, from: request)
            }
            return try ruleResponse {
                try jsonResponse(try requireRuleStore().upsertRule(body), status: .created)
            }
        }
        router.post("sessions/current/rules/:id/enable") { _, context -> Response in
            try ruleResponse {
                try jsonResponse(try requireRuleStore().setRuleEnabled(id: try idParameter(context), enabled: true))
            }
        }
        router.post("sessions/current/rules/:id/disable") { _, context -> Response in
            try ruleResponse {
                try jsonResponse(try requireRuleStore().setRuleEnabled(id: try idParameter(context), enabled: false))
            }
        }
        router.delete("sessions/current/rules/:id") { _, context -> Response in
            try ruleResponse {
                try requireRuleStore().removeRule(id: try idParameter(context))
                return try jsonResponse(["removed": true])
            }
        }
    }

    private func requireRuleStore() throws -> NetworkRuleStore {
        guard let ruleStore else {
            throw HTTPError(.notFound, message: "rule store is not available")
        }
        return ruleStore
    }

    private func idParameter(_ context: BasicRequestContext) throws -> String {
        guard let id = context.parameters.get("id"), !id.isEmpty else {
            throw HTTPError(.badRequest, message: "id route parameter is required")
        }
        return id
    }

    private func resolveRequest(_ request: NetworkRuleResolveRequest) throws -> NetworkRuleRequestContext {
        guard let components = URLComponents(string: request.url), components.scheme != nil else {
            throw NetworkRuleError.invalid("url must be absolute")
        }
        return NetworkRuleRequestContext(method: request.method, url: request.url, path: components.path.isEmpty ? "/" : components.path)
    }

    private func ruleResponse(_ operation: () throws -> Response) throws -> Response {
        do {
            return try operation()
        } catch let error as NetworkRuleError {
            switch error {
            case .notFound:
                throw HTTPError(.notFound, message: error.description)
            case .invalid, .missingValue:
                throw HTTPError(.badRequest, message: error.description)
            }
        }
    }
}
