import Foundation

struct NetworkMockRule: Codable, Equatable {
    let id: String
    var enabled: Bool
    var priority: Int
    var method: String
    var url: String
    var match: NetworkMockMatch
    var host: String?
    var query: [String: String]?
    var valueId: String
}

enum NetworkMockMatch: String, Codable {
    case exact
    case prefix
    case regex
}

struct NetworkMockValue: Codable, Equatable {
    let id: String
    var status: Int
    var headers: [String: String]
    var bodyRef: String
    var contentType: String
}

struct NetworkMockRuleRequest: Codable {
    let id: String
    let enabled: Bool?
    let priority: Int?
    let method: String
    let url: String
    let match: NetworkMockMatch?
    let host: String?
    let query: [String: String]?
    let valueId: String

    init(
        id: String,
        enabled: Bool?,
        priority: Int?,
        method: String,
        url: String,
        match: NetworkMockMatch?,
        host: String? = nil,
        query: [String: String]? = nil,
        valueId: String
    ) {
        self.id = id
        self.enabled = enabled
        self.priority = priority
        self.method = method
        self.url = url
        self.match = match
        self.host = host
        self.query = query
        self.valueId = valueId
    }
}

struct NetworkMockValueRequest: Codable {
    let id: String
    let status: Int?
    let headers: [String: String]?
    let body: String?
    let bodyBase64: String?
    let contentType: String?

    init(
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

struct NetworkMockRulesResponse: Codable {
    let rules: [NetworkMockRule]
}

struct NetworkMockValuesResponse: Codable {
    let values: [NetworkMockValue]
}

struct NetworkMockSetRequest: Codable {
    let rule: NetworkMockRuleRequest
    let value: NetworkMockValueRequest
}

struct NetworkMockSetResponse: Codable {
    let rule: NetworkMockRule
    let value: NetworkMockValue
}

struct NetworkMockExport: Codable {
    let rules: [NetworkMockRule]
    let values: [NetworkMockExportValue]
}

struct NetworkMockExportValue: Codable {
    let id: String
    let status: Int
    let headers: [String: String]
    let contentType: String
    let bodyBase64: String
}

struct NetworkMockResolveRequest: Codable {
    let method: String
    let url: String
}

struct NetworkMockResolveResponse: Codable {
    let matched: Bool
    let rule: NetworkMockRule?
    let value: NetworkMockValue?
}

struct NetworkMockRequest {
    let method: String
    let url: String
    let path: String
    let host: String
    let query: [String: String]

    init(method: String, url: String, path: String, host: String? = nil, query: [String: String]? = nil) {
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

struct NetworkMockResult {
    let rule: NetworkMockRule
    let value: NetworkMockValue
    let body: Data
}

public final class NetworkMockStore: @unchecked Sendable {
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var rules: [NetworkMockRule] = []
    private var values: [NetworkMockValue] = []

    let sessionDirectory: URL
    let rulesFile: URL
    let valuesFile: URL
    let bodiesDirectory: URL

    init(sessionDirectory: URL) throws {
        self.sessionDirectory = sessionDirectory
        rulesFile = sessionDirectory.appendingPathComponent("mock-rules.json")
        valuesFile = sessionDirectory.appendingPathComponent("mock-values.json")
        bodiesDirectory = sessionDirectory.appendingPathComponent("mock-values", isDirectory: true)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: bodiesDirectory, withIntermediateDirectories: true)
        try load()
    }

    func listRules() -> [NetworkMockRule] {
        lock.withLock { rules }
    }

    func listValues() -> [NetworkMockValue] {
        lock.withLock { values }
    }

    @discardableResult
    func upsertRule(_ request: NetworkMockRuleRequest) throws -> NetworkMockRule {
        try validateID(request.id, field: "rule id")
        try validateID(request.valueId, field: "value id")
        guard !request.method.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkMockError.invalid("method is required")
        }
        guard !request.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NetworkMockError.invalid("url is required")
        }
        let match = request.match ?? .exact
        if match == .regex, (try? NSRegularExpression(pattern: request.url)) == nil {
            throw NetworkMockError.invalid("url is not a valid regular expression: \(request.url)")
        }
        let host = normalizedHost(request.host)
        let query = normalizedQuery(request.query)
        lock.lock()
        defer { lock.unlock() }
        let rule = NetworkMockRule(
            id: request.id,
            enabled: request.enabled ?? true,
            priority: request.priority ?? 0,
            method: request.method.uppercased(),
            url: request.url,
            match: match,
            host: host,
            query: query,
            valueId: request.valueId
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
    func upsertValue(_ request: NetworkMockValueRequest) throws -> NetworkMockValue {
        try validateID(request.id, field: "value id")

        lock.lock()
        defer { lock.unlock() }
        let existingIndex = values.firstIndex(where: { $0.id == request.id })
        let existing = existingIndex.map { values[$0] }
        let status = request.status ?? existing?.status ?? 200
        guard (100...599).contains(status) else {
            throw NetworkMockError.invalid("status must be between 100 and 599")
        }
        let headers = request.headers ?? existing?.headers ?? [:]
        let contentType = request.contentType
            ?? headers.first { $0.key.lowercased() == "content-type" }?.value
            ?? existing?.contentType
            ?? "text/plain; charset=utf-8"
        let bodyRef = existing?.bodyRef ?? "\(request.id).body"
        if request.body != nil, request.bodyBase64 != nil {
            throw NetworkMockError.invalid("body and bodyBase64 are mutually exclusive")
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
    func set(_ request: NetworkMockSetRequest) throws -> NetworkMockSetResponse {
        let value = try upsertValue(request.value)
        let rule = try upsertRule(request.rule)
        return NetworkMockSetResponse(rule: rule, value: value)
    }

    @discardableResult
    func setRuleEnabled(id: String, enabled: Bool) throws -> NetworkMockRule {
        lock.lock()
        defer { lock.unlock() }
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            throw NetworkMockError.notFound("rule not found: \(id)")
        }
        rules[index].enabled = enabled
        try saveRulesLocked()
        return rules[index]
    }

    func removeRule(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            throw NetworkMockError.notFound("rule not found: \(id)")
        }
        rules.remove(at: index)
        try saveRulesLocked()
    }

    func removeValue(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if rules.contains(where: { $0.valueId == id }) {
            throw NetworkMockError.invalid("value is still referenced by a rule: \(id)")
        }
        guard let index = values.firstIndex(where: { $0.id == id }) else {
            throw NetworkMockError.notFound("value not found: \(id)")
        }
        let value = values.remove(at: index)
        try? FileManager.default.removeItem(at: bodyURL(for: value))
        try saveValuesLocked()
    }

    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        rules.removeAll()
        values.removeAll()
        try saveRulesLocked()
        try saveValuesLocked()
        try? FileManager.default.removeItem(at: bodiesDirectory)
        try FileManager.default.createDirectory(at: bodiesDirectory, withIntermediateDirectories: true)
    }

    func exportPackage() throws -> NetworkMockExport {
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
        return NetworkMockExport(rules: snapshot.0, values: exportedValues)
    }

    func importPackage(_ package: NetworkMockExport) throws {
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
            _ = try upsertRule(NetworkMockRuleRequest(
                id: rule.id,
                enabled: rule.enabled,
                priority: rule.priority,
                method: rule.method,
                url: rule.url,
                match: rule.match,
                host: rule.host,
                query: rule.query,
                valueId: rule.valueId
            ))
        }
    }

    func resolve(_ request: NetworkMockRequest) throws -> NetworkMockResult? {
        let snapshot = lock.withLock { rules.enumerated().map { ($0.offset, $0.element) } }
        let candidates = snapshot
            .filter { _, rule in rule.enabled && matchesMethod(rule.method, actual: request.method) && matches(rule, request: request) }
            .sorted {
                if $0.1.priority != $1.1.priority { return $0.1.priority > $1.1.priority }
                return $0.0 < $1.0
            }
        guard let rule = candidates.first?.1 else { return nil }
        let value = lock.withLock { values.first { $0.id == rule.valueId } }
        guard let value else {
            throw NetworkMockError.missingValue(ruleId: rule.id, valueId: rule.valueId)
        }
        let body = try Data(contentsOf: bodyURL(for: value))
        return NetworkMockResult(rule: rule, value: value, body: body)
    }

    private func load() throws {
        if FileManager.default.fileExists(atPath: rulesFile.path) {
            rules = try decoder.decode([NetworkMockRule].self, from: Data(contentsOf: rulesFile))
        }
        if FileManager.default.fileExists(atPath: valuesFile.path) {
            values = try decoder.decode([NetworkMockValue].self, from: Data(contentsOf: valuesFile))
        }
    }

    private func saveRulesLocked() throws {
        try encoder.encode(rules).write(to: rulesFile, options: [.atomic])
    }

    private func saveValuesLocked() throws {
        try encoder.encode(values).write(to: valuesFile, options: [.atomic])
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
                throw NetworkMockError.invalid("bodyBase64 is not valid base64")
            }
            return data
        }
        return nil
    }

    private func matches(_ rule: NetworkMockRule, request: NetworkMockRequest) -> Bool {
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
            throw NetworkMockError.invalid("\(field) is unsafe: \(id)")
        }
    }
}

enum NetworkMockError: Error, CustomStringConvertible {
    case invalid(String)
    case notFound(String)
    case missingValue(ruleId: String, valueId: String)

    var description: String {
        switch self {
        case .invalid(let message), .notFound(let message):
            return message
        case .missingValue(let ruleId, let valueId):
            return "mock rule \(ruleId) references missing value \(valueId)"
        }
    }
}
