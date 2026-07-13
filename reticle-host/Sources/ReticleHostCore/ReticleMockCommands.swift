import Foundation

func cmdMock(_ args: Args) throws {
    let client = try DaemonMockClient()
    switch args.positional(1) {
    case "list":
        try printMockRules(client.rules())
        try printMockValues(client.values())
    case "export":
        try exportMocks(client.exportPackage(), output: args.option("output"))
    case "import":
        try client.importPackage(try importPackage(input: try args.require("input")))
        print("mock import: ok")
    case "clear":
        try client.clear()
        print("mock clear: ok")
    case "set":
        let value = try client.setValue(valueRequest(args))
        let rule = try client.setRule(ruleRequest(args, defaultValueId: value.id))
        print("mock set: rule=\(rule.id) value=\(value.id)")
    case "rule":
        try cmdMockRule(args, client)
    case "value":
        try cmdMockValue(args, client)
    default:
        throw HelperError("unknown mock subcommand: \(args.positional(1) ?? "<none>")")
    }
}

private func cmdMockRule(_ args: Args, _ client: DaemonMockClient) throws {
    switch args.positional(2) {
    case "list":
        try printMockRules(client.rules())
    case "set":
        let rule = try client.setRule(ruleRequest(args, defaultValueId: nil))
        print("mock rule set: \(rule.id)")
    case "enable":
        let rule = try client.enableRule(id: try args.require("id"))
        print("mock rule enabled: \(rule.id)")
    case "disable":
        let rule = try client.disableRule(id: try args.require("id"))
        print("mock rule disabled: \(rule.id)")
    case "test":
        let result = try client.resolve(NetworkMockResolveRequest(method: try args.require("method"), url: try args.require("url")))
        if let rule = result.rule, let value = result.value {
            print("mock rule test: matched rule=\(rule.id) value=\(value.id) status=\(value.status)")
        } else {
            print("mock rule test: no match")
        }
    case "remove":
        try client.removeRule(id: try args.require("id"))
        print("mock rule removed: \(try args.require("id"))")
    default:
        throw HelperError("unknown mock rule subcommand: \(args.positional(2) ?? "<none>")")
    }
}

private func cmdMockValue(_ args: Args, _ client: DaemonMockClient) throws {
    switch args.positional(2) {
    case "list":
        try printMockValues(client.values())
    case "set":
        let value = try client.setValue(valueRequest(args))
        print("mock value set: \(value.id)")
    case "remove":
        try client.removeValue(id: try args.require("id"))
        print("mock value removed: \(try args.require("id"))")
    default:
        throw HelperError("unknown mock value subcommand: \(args.positional(2) ?? "<none>")")
    }
}

private func ruleRequest(_ args: Args, defaultValueId: String?) throws -> NetworkMockRuleRequest {
    let valueId = args.option("value-id") ?? defaultValueId
    guard let valueId else { throw HelperError("missing required --value-id") }
    let match: NetworkMockMatch
    if let raw = args.option("match") {
        guard let parsed = NetworkMockMatch(rawValue: raw) else {
            throw HelperError("--match must be exact or prefix")
        }
        match = parsed
    } else {
        match = .exact
    }
    return NetworkMockRuleRequest(
        id: try args.require("id"),
        enabled: args.option("disabled") == "true" ? false : nil,
        priority: args.option("priority").flatMap(Int.init),
        method: try args.require("method"),
        url: try args.require("url"),
        match: match,
        host: args.option("host"),
        query: try stringObjectOption(args.option("query"), name: "--query"),
        valueId: valueId
    )
}

private func valueRequest(_ args: Args) throws -> NetworkMockValueRequest {
    let id: String
    if let valueId = args.option("value-id") {
        id = valueId
    } else {
        id = try args.require("id")
    }
    let body = try bodyOption(args)
    return NetworkMockValueRequest(
        id: id,
        status: args.option("status").flatMap(Int.init),
        headers: try stringObjectOption(args.option("headers"), name: "--headers"),
        body: body.text,
        bodyBase64: body.base64,
        contentType: args.option("content-type")
    )
}

private func stringObjectOption(_ raw: String?, name: String) throws -> [String: String]? {
    guard let raw else { return nil }
    guard let data = raw.data(using: .utf8) else { return nil }
    let any = try JSONSerialization.jsonObject(with: data)
    guard let object = any as? [String: Any] else {
        throw HelperError("\(name) must be a JSON object")
    }
    var values: [String: String] = [:]
    for (key, value) in object {
        values[key] = "\(value)"
    }
    return values
}

private func bodyOption(_ args: Args) throws -> (text: String?, base64: String?) {
    if let body = args.option("body") { return (body, nil) }
    if let path = args.option("body-file") {
        return (nil, try Data(contentsOf: URL(fileURLWithPath: path)).base64EncodedString())
    }
    return (nil, nil)
}

private func exportMocks(_ package: NetworkMockExport, output: String?) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(package)
    if let output {
        try data.write(to: URL(fileURLWithPath: output), options: [.atomic])
        print("mock export: \(output)")
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private func importPackage(input: String) throws -> NetworkMockExport {
    try JSONDecoder().decode(NetworkMockExport.self, from: Data(contentsOf: URL(fileURLWithPath: input)))
}

private func printMockRules(_ rules: [NetworkMockRule]) {
    if rules.isEmpty {
        print("mock rules: none")
        return
    }
    print("mock rules:")
    for rule in rules {
        var qualifiers: [String] = []
        if let host = rule.host { qualifiers.append("host=\(host)") }
        if let query = rule.query, !query.isEmpty { qualifiers.append("query=\(query)") }
        let suffix = qualifiers.isEmpty ? "" : " \(qualifiers.joined(separator: " "))"
        print("  \(rule.id) \(rule.enabled ? "on" : "off") priority=\(rule.priority) \(rule.method) \(rule.match.rawValue) \(rule.url)\(suffix) -> \(rule.valueId)")
    }
}

private func printMockValues(_ values: [NetworkMockValue]) {
    if values.isEmpty {
        print("mock values: none")
        return
    }
    print("mock values:")
    for value in values {
        print("  \(value.id) status=\(value.status) contentType=\(value.contentType) bodyRef=\(value.bodyRef)")
    }
}

private final class DaemonMockClient {
    private let baseURL: URL
    private let timeout: TimeInterval

    init(discovery: DaemonDiscovery = DaemonDiscovery(), timeout: TimeInterval = 2.0) throws {
        guard let info = discovery.readLive() else {
            throw HelperError("reticle serve is not running; start it before using reticle mock")
        }
        guard let baseURL = URL(string: "http://127.0.0.1:\(info.port)/sessions/current/mocks/") else {
            throw HelperError("invalid daemon URL")
        }
        self.baseURL = baseURL
        self.timeout = timeout
    }

    func rules() throws -> [NetworkMockRule] {
        try request("rules", method: "GET", response: NetworkMockRulesResponse.self).rules
    }

    func values() throws -> [NetworkMockValue] {
        try request("values", method: "GET", response: NetworkMockValuesResponse.self).values
    }

    func exportPackage() throws -> NetworkMockExport {
        try request("export", method: "GET", response: NetworkMockExport.self)
    }

    func importPackage(_ package: NetworkMockExport) throws {
        let _: EmptyResponse = try request("import", method: "POST", body: package, response: EmptyResponse.self)
    }

    func clear() throws {
        let _: EmptyResponse = try request("clear", method: "POST", response: EmptyResponse.self)
    }

    func resolve(_ request: NetworkMockResolveRequest) throws -> NetworkMockResolveResponse {
        try self.request("resolve", method: "POST", body: request, response: NetworkMockResolveResponse.self)
    }

    func setRule(_ rule: NetworkMockRuleRequest) throws -> NetworkMockRule {
        try request("rules", method: "POST", body: rule, response: NetworkMockRule.self)
    }

    func enableRule(id: String) throws -> NetworkMockRule {
        try request("rules/\(encoded(id))/enable", method: "POST", response: NetworkMockRule.self)
    }

    func disableRule(id: String) throws -> NetworkMockRule {
        try request("rules/\(encoded(id))/disable", method: "POST", response: NetworkMockRule.self)
    }

    func removeRule(id: String) throws {
        try requestIgnoringBody("rules/\(encoded(id))", method: "DELETE")
    }

    func setValue(_ value: NetworkMockValueRequest) throws -> NetworkMockValue {
        try request("values", method: "POST", body: value, response: NetworkMockValue.self)
    }

    func removeValue(id: String) throws {
        try requestIgnoringBody("values/\(encoded(id))", method: "DELETE")
    }

    private func request<T: Decodable>(_ path: String, method: String, response: T.Type) throws -> T {
        try perform(path: path, method: method, body: Optional<Data>.none, response: response)
    }

    private func request<B: Encodable, T: Decodable>(_ path: String, method: String, body: B, response: T.Type) throws -> T {
        try perform(path: path, method: method, body: try JSONEncoder().encode(body), response: response)
    }

    private func requestIgnoringBody(_ path: String, method: String) throws {
        let _: EmptyResponse = try perform(path: path, method: method, body: Optional<Data>.none, response: EmptyResponse.self)
    }

    private func perform<T: Decodable>(path: String, method: String, body: Data?, response: T.Type) throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw HelperError("invalid daemon mock API path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<Data>(fallback: .failure(HelperError("daemon mock API returned no result")))
        let task = URLSession.shared.dataTask(with: request) { data, rawResponse, error in
            defer { semaphore.signal() }
            if let error {
                box.set(.failure(error))
                return
            }
            let status = (rawResponse as? HTTPURLResponse)?.statusCode ?? 0
            let data = data ?? Data()
            guard (200..<300).contains(status) else {
                let message = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                box.set(.failure(HelperError("daemon mock API failed with HTTP \(status): \(message)")))
                return
            }
            box.set(.success(data))
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw HelperError("daemon mock API timed out")
        }
        return try JSONDecoder().decode(T.self, from: try box.value.get())
    }

    private func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

private struct EmptyResponse: Decodable {}

