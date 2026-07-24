import Foundation

// MARK: - Rule matcher

/// How a rule's `url` field is compared against captured traffic.
public enum NetworkRuleMatch: String, Codable {
    case exact
    case prefix
    case regex
}

// MARK: - Rule actions

/// How a matched rule sources its response. Mutually exclusive — modeled as a sum
/// type so illegal combinations (block AND mock AND mapRemote) are unrepresentable.
/// Mirrors Loom's `Route` so the translation to the engine is 1:1.
///
/// - `passthrough`: fetch the original upstream (the default; only meaningful with
///   modifiers like a delay or a header rewrite).
/// - `block`: short-circuit with a connection failure; upstream is never contacted.
/// - `mock`: reply with a stored reusable response value (referenced by id).
/// - `mapRemote`: re-target the request at a different origin, keeping path + query.
public enum NetworkRoute: Codable, Equatable {
    case passthrough
    case block
    case mock(valueId: String)
    case mapRemote(NetworkMapRemote)

    private enum CodingKeys: String, CodingKey { case type, valueId, mapRemote }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .passthrough: try c.encode("passthrough", forKey: .type)
        case .block: try c.encode("block", forKey: .type)
        case let .mock(valueId):
            try c.encode("mock", forKey: .type)
            try c.encode(valueId, forKey: .valueId)
        case let .mapRemote(action):
            try c.encode("mapRemote", forKey: .type)
            try c.encode(action, forKey: .mapRemote)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "passthrough": self = .passthrough
        case "block": self = .block
        case "mock": self = .mock(valueId: try c.decode(String.self, forKey: .valueId))
        case "mapRemote": self = .mapRemote(try c.decode(NetworkMapRemote.self, forKey: .mapRemote))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "unknown route \"\(other)\"")
        }
    }

    /// A stable label for the route, surfaced on captured evidence as `ruleAction`.
    public var label: String {
        switch self {
        case .passthrough: return "passthrough"
        case .block: return "block"
        case .mock: return "mock"
        case .mapRemote: return "mapRemote"
        }
    }
}

/// Re-target a matched request at a different origin (scheme + host + optional port),
/// keeping the original path and query.
public struct NetworkMapRemote: Codable, Equatable {
    /// Origin to route to, e.g. `https://staging.example.com` or `http://127.0.0.1:3001`.
    public var destination: String
    /// Keep the original `Host` header instead of letting it follow the new origin.
    public var keepHostHeader: Bool

    public init(destination: String, keepHostHeader: Bool = false) {
        self.destination = destination
        self.keepHostHeader = keepHostHeader
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        destination = try c.decode(String.self, forKey: .destination)
        keepHostHeader = try c.decodeIfPresent(Bool.self, forKey: .keepHostHeader) ?? false
    }
}

/// Add/overwrite or remove headers on a request or response.
public struct NetworkHeaderRewrite: Codable, Equatable {
    /// Header name → value to add or overwrite (matched case-insensitively by name).
    public var setHeaders: [String: String]
    /// Header names to remove (matched case-insensitively).
    public var removeHeaders: [String]

    public init(setHeaders: [String: String] = [:], removeHeaders: [String] = []) {
        self.setHeaders = setHeaders
        self.removeHeaders = removeHeaders
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        setHeaders = try c.decodeIfPresent([String: String].self, forKey: .setHeaders) ?? [:]
        removeHeaders = try c.decodeIfPresent([String].self, forKey: .removeHeaders) ?? []
    }

    public var isEmpty: Bool { setHeaders.isEmpty && removeHeaders.isEmpty }
}

/// A find/replace substitution applied to one part of the request or response.
public struct NetworkSubstitution: Codable, Equatable {
    public enum Field: String, Codable, CaseIterable {
        case url      // request line / query (request side only)
        case header   // header values
        case body     // body text
    }

    public var field: Field
    public var match: String
    public var replacement: String
    public var isRegex: Bool
    public var caseSensitive: Bool

    public init(
        field: Field,
        match: String,
        replacement: String,
        isRegex: Bool = false,
        caseSensitive: Bool = false
    ) {
        self.field = field
        self.match = match
        self.replacement = replacement
        self.isRegex = isRegex
        self.caseSensitive = caseSensitive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decode(Field.self, forKey: .field)
        match = try c.decode(String.self, forKey: .match)
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        isRegex = try c.decodeIfPresent(Bool.self, forKey: .isRegex) ?? false
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
    }
}

/// The full action bundle a rule applies to matching traffic: one `route` (how the
/// response is sourced) plus orthogonal modifiers that compose with it.
public struct NetworkRuleActions: Codable, Equatable {
    public var route: NetworkRoute
    /// Delay before the response is released to the client (crude throttle), ms.
    public var delayMs: Int?
    public var rewriteRequest: NetworkHeaderRewrite?
    public var rewriteResponse: NetworkHeaderRewrite?
    public var requestSubstitutions: [NetworkSubstitution]
    public var responseSubstitutions: [NetworkSubstitution]

    private enum CodingKeys: String, CodingKey {
        case route, delayMs, rewriteRequest, rewriteResponse, requestSubstitutions, responseSubstitutions
    }

    public init(
        route: NetworkRoute = .passthrough,
        delayMs: Int? = nil,
        rewriteRequest: NetworkHeaderRewrite? = nil,
        rewriteResponse: NetworkHeaderRewrite? = nil,
        requestSubstitutions: [NetworkSubstitution] = [],
        responseSubstitutions: [NetworkSubstitution] = []
    ) {
        self.route = route
        self.delayMs = delayMs
        self.rewriteRequest = rewriteRequest
        self.rewriteResponse = rewriteResponse
        self.requestSubstitutions = requestSubstitutions
        self.responseSubstitutions = responseSubstitutions
    }

    // Tolerant decode: a rule authored with only a route (or none) still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        route = try c.decodeIfPresent(NetworkRoute.self, forKey: .route) ?? .passthrough
        delayMs = try c.decodeIfPresent(Int.self, forKey: .delayMs)
        rewriteRequest = try c.decodeIfPresent(NetworkHeaderRewrite.self, forKey: .rewriteRequest)
        rewriteResponse = try c.decodeIfPresent(NetworkHeaderRewrite.self, forKey: .rewriteResponse)
        requestSubstitutions = try c.decodeIfPresent([NetworkSubstitution].self, forKey: .requestSubstitutions) ?? []
        responseSubstitutions = try c.decodeIfPresent([NetworkSubstitution].self, forKey: .responseSubstitutions) ?? []
    }

    /// True when the bundle changes nothing — a `passthrough` route with no modifiers.
    public var isNoOp: Bool {
        guard case .passthrough = route else { return false }
        return delayMs == nil
            && (rewriteRequest?.isEmpty ?? true)
            && (rewriteResponse?.isEmpty ?? true)
            && requestSubstitutions.isEmpty
            && responseSubstitutions.isEmpty
    }
}

// MARK: - Rule

/// A traffic rule: a matcher (method/url/host/query) plus the `actions` applied to
/// matching traffic. Replaces the mock-only rule — `actions.route` now covers block,
/// mock, and mapRemote alongside request/response modifiers.
public struct NetworkRule: Codable, Equatable {
    public let id: String
    public var enabled: Bool
    public var priority: Int
    public var method: String
    public var url: String
    public var match: NetworkRuleMatch
    public var host: String?
    public var query: [String: String]?
    public var actions: NetworkRuleActions

    public init(
        id: String,
        enabled: Bool,
        priority: Int,
        method: String,
        url: String,
        match: NetworkRuleMatch,
        host: String?,
        query: [String: String]?,
        actions: NetworkRuleActions
    ) {
        self.id = id
        self.enabled = enabled
        self.priority = priority
        self.method = method
        self.url = url
        self.match = match
        self.host = host
        self.query = query
        self.actions = actions
    }

    /// The response value id this rule references, when its route is `mock`.
    public var mockValueId: String? {
        if case let .mock(valueId) = actions.route { return valueId }
        return nil
    }
}

// MARK: - Reusable response value (mock body)

/// A reusable canned response, referenced by a rule whose route is `mock`. Kept as a
/// separate store so one response can back several rules; the body lives on disk.
public struct NetworkMockValue: Codable, Equatable {
    public let id: String
    public var status: Int
    public var headers: [String: String]
    public var bodyRef: String
    public var contentType: String
}

// MARK: - Request / response DTOs

public struct NetworkRuleRequest: Codable {
    public let id: String
    public let enabled: Bool?
    public let priority: Int?
    public let method: String
    public let url: String
    public let match: NetworkRuleMatch?
    public let host: String?
    public let query: [String: String]?
    public let actions: NetworkRuleActions

    public init(
        id: String,
        enabled: Bool?,
        priority: Int?,
        method: String,
        url: String,
        match: NetworkRuleMatch?,
        host: String? = nil,
        query: [String: String]? = nil,
        actions: NetworkRuleActions
    ) {
        self.id = id
        self.enabled = enabled
        self.priority = priority
        self.method = method
        self.url = url
        self.match = match
        self.host = host
        self.query = query
        self.actions = actions
    }
}

public struct NetworkMockValueRequest: Codable {
    public let id: String
    public let status: Int?
    public let headers: [String: String]?
    public let body: String?
    public let bodyBase64: String?
    public let contentType: String?

    public init(
        id: String,
        status: Int?,
        headers: [String: String]?,
        body: String?,
        bodyBase64: String? = nil,
        contentType: String?
    ) {
        self.id = id
        self.status = status
        self.headers = headers
        self.body = body
        self.bodyBase64 = bodyBase64
        self.contentType = contentType
    }
}

public struct NetworkRulesResponse: Codable {
    public let rules: [NetworkRule]

    public init(rules: [NetworkRule]) {
        self.rules = rules
    }
}

public struct NetworkMockValuesResponse: Codable {
    public let values: [NetworkMockValue]

    public init(values: [NetworkMockValue]) {
        self.values = values
    }
}

public struct NetworkRuleSetRequest: Codable {
    public let rule: NetworkRuleRequest
    public let value: NetworkMockValueRequest?
}

public struct NetworkRuleSetResponse: Codable {
    public let rule: NetworkRule
    public let value: NetworkMockValue?
}

public struct NetworkRuleExport: Codable {
    public let rules: [NetworkRule]
    public let values: [NetworkMockExportValue]
}

public struct NetworkMockExportValue: Codable {
    public let id: String
    public let status: Int
    public let headers: [String: String]
    public let contentType: String
    public let bodyBase64: String
}

public struct NetworkRuleResolveRequest: Codable {
    public let method: String
    public let url: String

    public init(method: String, url: String) {
        self.method = method
        self.url = url
    }
}

public struct NetworkRuleResolveResponse: Codable {
    public let matched: Bool
    public let rule: NetworkRule?
    /// The referenced response value, present only when the matched rule's route is `mock`.
    public let value: NetworkMockValue?

    public init(matched: Bool, rule: NetworkRule?, value: NetworkMockValue?) {
        self.matched = matched
        self.rule = rule
        self.value = value
    }
}

public struct NetworkRuleRequestContext {
    public let method: String
    public let url: String
    public let path: String
    public let host: String
    public let query: [String: String]

    public init(method: String, url: String, path: String, host: String? = nil, query: [String: String]? = nil) {
        self.method = method
        self.url = url
        self.path = Self.pathWithoutQuery(path)
        let parsed = URLComponents(string: url)
        self.host = (host ?? parsed?.host ?? "").lowercased()
        self.query = query ?? Self.queryItems(from: parsed)
    }

    private static func pathWithoutQuery(_ path: String) -> String {
        let value = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        return value.isEmpty ? "/" : value
    }

    private static func queryItems(from components: URLComponents?) -> [String: String] {
        var result: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            result[item.name] = item.value ?? ""
        }
        return result
    }
}

/// The outcome of resolving a request against the rule set: the winning rule and,
/// for a `mock` route, its response value and body bytes.
public struct NetworkRuleResult {
    public let rule: NetworkRule
    public let value: NetworkMockValue?
    public let body: Data?
}

// MARK: - Store

public final class NetworkRuleStore: @unchecked Sendable {
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var rules: [NetworkRule] = []
    private var values: [NetworkMockValue] = []

    let sessionDirectory: URL
    let rulesFile: URL
    let valuesFile: URL
    let bodiesDirectory: URL

    /// Invoked after any mutation persists, so an external consumer (e.g. a
    /// Loom-backed capture lane) can re-sync the rule set. Fired while the store
    /// lock is held — the handler must not re-enter the store synchronously; it
    /// should only enqueue work.
    public var onChange: (() -> Void)?

    public init(sessionDirectory: URL) throws {
        self.sessionDirectory = sessionDirectory
        rulesFile = sessionDirectory.appendingPathComponent("rules.json")
        valuesFile = sessionDirectory.appendingPathComponent("rule-values.json")
        bodiesDirectory = sessionDirectory.appendingPathComponent("rule-values", isDirectory: true)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: bodiesDirectory, withIntermediateDirectories: true)
        try load()
    }

    public func listRules() -> [NetworkRule] {
        lock.withLock { rules }
    }

    public func listValues() -> [NetworkMockValue] {
        lock.withLock { values }
    }

    @discardableResult
    public func upsertRule(_ request: NetworkRuleRequest) throws -> NetworkRule {
        try validateID(request.id, field: "rule id")
        guard !request.method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkRuleError.invalid("method is required")
        }
        guard !request.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkRuleError.invalid("url is required")
        }
        let match = request.match ?? .exact
        if match == .regex, (try? NSRegularExpression(pattern: request.url)) == nil {
            throw NetworkRuleError.invalid("url is not a valid regular expression: \(request.url)")
        }
        try validateActions(request.actions)
        let host = normalizedHost(request.host)
        let query = normalizedQuery(request.query)
        lock.lock()
        defer { lock.unlock() }
        let rule = NetworkRule(
            id: request.id,
            enabled: request.enabled ?? true,
            priority: request.priority ?? 0,
            method: request.method.uppercased(),
            url: request.url,
            match: match,
            host: host,
            query: query,
            actions: request.actions
        )
        if let index = rules.firstIndex(where: { $0.id == request.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
        try saveRulesLocked()
        return rule
    }

    @discardableResult
    public func upsertValue(_ request: NetworkMockValueRequest) throws -> NetworkMockValue {
        try validateID(request.id, field: "value id")

        lock.lock()
        defer { lock.unlock() }
        let existingIndex = values.firstIndex(where: { $0.id == request.id })
        let existing = existingIndex.map { values[$0] }
        let status = request.status ?? existing?.status ?? 200
        guard (100...599).contains(status) else {
            throw NetworkRuleError.invalid("status must be between 100 and 599")
        }
        let headers = request.headers ?? existing?.headers ?? [:]
        let contentType = request.contentType
            ?? headers.first { $0.key.lowercased() == "content-type" }?.value
            ?? existing?.contentType
            ?? "text/plain; charset=utf-8"
        let bodyRef = existing?.bodyRef ?? "\(request.id).body"
        if request.body != nil, request.bodyBase64 != nil {
            throw NetworkRuleError.invalid("body and bodyBase64 are mutually exclusive")
        }
        if let bodyData = try requestBodyData(request) {
            try bodyData.write(to: bodiesDirectory.appendingPathComponent(bodyRef), options: [.atomic])
        } else if existing == nil {
            try Data().write(to: bodiesDirectory.appendingPathComponent(bodyRef), options: [.atomic])
        }
        let value = NetworkMockValue(
            id: request.id,
            status: status,
            headers: headers,
            bodyRef: bodyRef,
            contentType: contentType
        )
        if let index = existingIndex {
            values[index] = value
        } else {
            values.append(value)
        }
        try saveValuesLocked()
        return value
    }

    @discardableResult
    public func set(_ request: NetworkRuleSetRequest) throws -> NetworkRuleSetResponse {
        let value = try request.value.map { try upsertValue($0) }
        let rule = try upsertRule(request.rule)
        return NetworkRuleSetResponse(rule: rule, value: value)
    }

    @discardableResult
    public func setRuleEnabled(id: String, enabled: Bool) throws -> NetworkRule {
        lock.lock()
        defer { lock.unlock() }
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            throw NetworkRuleError.notFound("rule not found: \(id)")
        }
        rules[index].enabled = enabled
        try saveRulesLocked()
        return rules[index]
    }

    public func removeRule(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            throw NetworkRuleError.notFound("rule not found: \(id)")
        }
        rules.remove(at: index)
        try saveRulesLocked()
    }

    public func removeValue(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if rules.contains(where: { $0.mockValueId == id }) {
            throw NetworkRuleError.invalid("value is still referenced by a rule: \(id)")
        }
        guard let index = values.firstIndex(where: { $0.id == id }) else {
            throw NetworkRuleError.notFound("value not found: \(id)")
        }
        let value = values.remove(at: index)
        try? FileManager.default.removeItem(at: bodyURL(for: value))
        try saveValuesLocked()
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        rules.removeAll()
        values.removeAll()
        try saveRulesLocked()
        try saveValuesLocked()
        try? FileManager.default.removeItem(at: bodiesDirectory)
        try FileManager.default.createDirectory(at: bodiesDirectory, withIntermediateDirectories: true)
    }

    public func exportPackage() throws -> NetworkRuleExport {
        let snapshot = lock.withLock { (rules, values) }
        let exportedValues = try snapshot.1.map { value in
            NetworkMockExportValue(
                id: value.id,
                status: value.status,
                headers: value.headers,
                contentType: value.contentType,
                bodyBase64: try Data(contentsOf: bodyURL(for: value)).base64EncodedString()
            )
        }
        return NetworkRuleExport(rules: snapshot.0, values: exportedValues)
    }

    public func importPackage(_ package: NetworkRuleExport) throws {
        for value in package.values {
            _ = try upsertValue(NetworkMockValueRequest(
                id: value.id,
                status: value.status,
                headers: value.headers,
                body: nil,
                bodyBase64: value.bodyBase64,
                contentType: value.contentType
            ))
        }
        for rule in package.rules {
            _ = try upsertRule(NetworkRuleRequest(
                id: rule.id,
                enabled: rule.enabled,
                priority: rule.priority,
                method: rule.method,
                url: rule.url,
                match: rule.match,
                host: rule.host,
                query: rule.query,
                actions: rule.actions
            ))
        }
    }

    public func resolve(_ request: NetworkRuleRequestContext) throws -> NetworkRuleResult? {
        let snapshot = lock.withLock { rules.enumerated().map { ($0.offset, $0.element) } }
        let candidates = snapshot
            .filter { _, rule in rule.enabled && matchesMethod(rule.method, actual: request.method) && matches(rule, request: request) }
            .sorted {
                if $0.1.priority != $1.1.priority { return $0.1.priority > $1.1.priority }
                return $0.0 < $1.0
            }
        guard let rule = candidates.first?.1 else { return nil }
        guard let valueId = rule.mockValueId else {
            // A non-mock route (block / mapRemote / passthrough-with-modifiers) has no
            // stored response value to preview.
            return NetworkRuleResult(rule: rule, value: nil, body: nil)
        }
        let value = lock.withLock { values.first { $0.id == valueId } }
        guard let value else {
            throw NetworkRuleError.missingValue(ruleId: rule.id, valueId: valueId)
        }
        let body = try Data(contentsOf: bodyURL(for: value))
        return NetworkRuleResult(rule: rule, value: value, body: body)
    }

    private func load() throws {
        if FileManager.default.fileExists(atPath: rulesFile.path) {
            rules = try decoder.decode([NetworkRule].self, from: Data(contentsOf: rulesFile))
        }
        if FileManager.default.fileExists(atPath: valuesFile.path) {
            values = try decoder.decode([NetworkMockValue].self, from: Data(contentsOf: valuesFile))
        }
    }

    private func saveRulesLocked() throws {
        try encoder.encode(rules).write(to: rulesFile, options: [.atomic])
        onChange?()
    }

    private func saveValuesLocked() throws {
        try encoder.encode(values).write(to: valuesFile, options: [.atomic])
        onChange?()
    }

    private func bodyURL(for value: NetworkMockValue) -> URL {
        bodiesDirectory.appendingPathComponent(value.bodyRef)
    }

    private func requestBodyData(_ request: NetworkMockValueRequest) throws -> Data? {
        if let body = request.body {
            return Data(body.utf8)
        }
        if let bodyBase64 = request.bodyBase64 {
            guard let data = Data(base64Encoded: bodyBase64) else {
                throw NetworkRuleError.invalid("bodyBase64 is not valid base64")
            }
            return data
        }
        return nil
    }

    private func validateActions(_ actions: NetworkRuleActions) throws {
        switch actions.route {
        case .mock(let valueId):
            try validateID(valueId, field: "value id")
        case .mapRemote(let action):
            let destination = action.destination.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !destination.isEmpty else {
                throw NetworkRuleError.invalid("mapRemote destination is required")
            }
            guard let components = URLComponents(string: destination),
                  let scheme = components.scheme, !scheme.isEmpty,
                  let host = components.host, !host.isEmpty else {
                throw NetworkRuleError.invalid("mapRemote destination must be an absolute origin (scheme://host[:port]): \(destination)")
            }
        case .block, .passthrough:
            break
        }
        if let delay = actions.delayMs, delay < 0 {
            throw NetworkRuleError.invalid("delayMs must be non-negative")
        }
        for sub in actions.requestSubstitutions + actions.responseSubstitutions where sub.isRegex {
            if (try? NSRegularExpression(pattern: sub.match)) == nil {
                throw NetworkRuleError.invalid("substitution match is not a valid regular expression: \(sub.match)")
            }
        }
    }

    private func matches(_ rule: NetworkRule, request: NetworkRuleRequestContext) -> Bool {
        if let host = rule.host, !matchesHost(host, actual: request.host) {
            return false
        }
        if let query = rule.query, !matchesQuery(query, actual: request.query) {
            return false
        }
        let actual = rule.url.hasPrefix("/") ? request.path : request.url
        switch rule.match {
        case .exact:
            return actual == rule.url
        case .prefix:
            return actual.hasPrefix(rule.url)
        case .regex:
            // A regex often anchors on the path (`^/api/...`), so the literal-URL
            // "starts with /" heuristic doesn't apply. Match against both the
            // path and the full URL so either intent works.
            return request.path.range(of: rule.url, options: .regularExpression) != nil
                || request.url.range(of: rule.url, options: .regularExpression) != nil
        }
    }

    /// `ANY` is a method wildcard; every other value matches case-insensitively.
    private func matchesMethod(_ expected: String, actual: String) -> Bool {
        expected == "ANY" || expected == actual.uppercased()
    }

    private func matchesHost(_ expected: String, actual: String) -> Bool {
        guard !expected.isEmpty else { return true }
        if expected.hasPrefix("*.") {
            let suffix = String(expected.dropFirst())
            return actual.hasSuffix(suffix) && actual.count > suffix.count
        }
        return actual == expected
    }

    private func matchesQuery(_ expected: [String: String], actual: [String: String]) -> Bool {
        for (key, value) in expected {
            if value == "*" {
                // Presence-only predicate: the key must exist with any value.
                guard actual[key] != nil else { return false }
            } else {
                guard actual[key] == value else { return false }
            }
        }
        return true
    }

    private func normalizedHost(_ host: String?) -> String? {
        guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return nil
        }
        return host.lowercased()
    }

    private func normalizedQuery(_ query: [String: String]?) -> [String: String]? {
        guard let query, !query.isEmpty else { return nil }
        return query
    }

    private func validateID(_ id: String, field: String) throws {
        let valid = id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
        guard valid, id != ".", id != ".." else {
            throw NetworkRuleError.invalid("\(field) is unsafe: \(id)")
        }
    }
}

public enum NetworkRuleError: Error, CustomStringConvertible {
    case invalid(String)
    case notFound(String)
    case missingValue(ruleId: String, valueId: String)

    public var description: String {
        switch self {
        case .invalid(let message), .notFound(let message):
            return message
        case .missingValue(let ruleId, let valueId):
            return "rule \(ruleId) references missing value \(valueId)"
        }
    }
}
