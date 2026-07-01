import Foundation

struct NetworkMockRule: Codable, Equatable {
    let id: String
    var enabled: Bool
    var priority: Int
    var method: String
    var url: String
    var match: NetworkMockMatch
    var valueId: String
}

enum NetworkMockMatch: String, Codable {
    case exact
    case prefix
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
    let valueId: String
}

struct NetworkMockValueRequest: Codable {
    let id: String
    let status: Int?
    let headers: [String: String]?
    let body: String?
    let contentType: String?
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

struct NetworkMockRequest {
    let method: String
    let url: String
    let path: String
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
        lock.lock()
        defer { lock.unlock() }
        let rule = NetworkMockRule(
            id: request.id,
            enabled: request.enabled ?? true,
            priority: request.priority ?? 0,
            method: request.method.uppercased(),
            url: request.url,
            match: request.match ?? .exact,
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
        if let body = request.body {
            try Data(body.utf8).write(to: bodiesDirectory.appendingPathComponent(bodyRef), options: [.atomic])
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

    func resolve(_ request: NetworkMockRequest) throws -> NetworkMockResult? {
        let snapshot = lock.withLock { rules.enumerated().map { ($0.offset, $0.element) } }
        let candidates = snapshot
            .filter { _, rule in rule.enabled && rule.method == request.method.uppercased() && matches(rule, request: request) }
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

    private func matches(_ rule: NetworkMockRule, request: NetworkMockRequest) -> Bool {
        let actual = rule.url.hasPrefix("/") ? request.path : request.url
        switch rule.match {
        case .exact:
            return actual == rule.url
        case .prefix:
            return actual.hasPrefix(rule.url)
        }
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
