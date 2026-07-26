import Foundation

func cmdRule(_ args: Args) throws {
    let client = try DaemonRuleClient()
    switch args.positional(1) {
    case "list":
        try printRules(client.rules())
        try printValues(client.values())
    case "export":
        try exportRules(client.exportPackage(), output: args.option("output"))
    case "import":
        try client.importPackage(try importPackage(input: try args.require("input")))
        print("rule import: ok")
    case "clear":
        try client.clear()
        print("rule clear: ok")
    case "set":
        let ruleId = try args.require("id")
        let actions = try ruleActions(args, ruleId: ruleId)
        // A mock route sources its response from a stored value; upsert it first
        // (merging with any existing value) so the rule can reference it.
        if case let .mock(valueId) = actions.route {
            _ = try client.setValue(valueRequest(args, valueId: valueId))
        }
        let rule = try client.setRule(ruleRequest(args, id: ruleId, actions: actions))
        print("rule set: \(rule.id) [\(rule.actions.route.label)]")
    case "enable":
        let rule = try client.enableRule(id: try args.require("id"))
        print("rule enabled: \(rule.id)")
    case "disable":
        let rule = try client.disableRule(id: try args.require("id"))
        print("rule disabled: \(rule.id)")
    case "test":
        let result = try client.resolve(NetworkRuleResolveRequest(method: try args.require("method"), url: try args.require("url")))
        if let rule = result.rule {
            let value = result.value.map { " value=\($0.id) status=\($0.status)" } ?? ""
            print("rule test: matched rule=\(rule.id) action=\(rule.actions.route.label)\(value)")
        } else {
            print("rule test: no match")
        }
    case "remove":
        try client.removeRule(id: try args.require("id"))
        print("rule removed: \(try args.require("id"))")
    case "value":
        try cmdRuleValue(args, client)
    default:
        throw HelperError("unknown rule subcommand: \(args.positional(1) ?? "<none>") (expected: list|set|enable|disable|test|remove|value|export|import|clear)")
    }
}

private func cmdRuleValue(_ args: Args, _ client: DaemonRuleClient) throws {
    switch args.positional(2) {
    case "list":
        try printValues(client.values())
    case "set":
        let value = try client.setValue(valueRequest(args, valueId: args.option("value-id") ?? args.require("id")))
        print("rule value set: \(value.id)")
    case "remove":
        try client.removeValue(id: try args.require("id"))
        print("rule value removed: \(try args.require("id"))")
    default:
        throw HelperError("unknown rule value subcommand: \(args.positional(2) ?? "<none>")")
    }
}

// MARK: - Request builders

private func ruleRequest(_ args: Args, id: String, actions: NetworkRuleActions) throws -> NetworkRuleRequest {
    let match: NetworkRuleMatch
    if let raw = args.option("match") {
        guard let parsed = NetworkRuleMatch(rawValue: raw) else {
            throw HelperError("--match must be exact, prefix, or regex")
        }
        match = parsed
    } else {
        match = .exact
    }
    return NetworkRuleRequest(
        id: id,
        enabled: args.option("disabled") == "true" ? false : nil,
        priority: args.option("priority").flatMap(Int.init),
        method: try args.require("method"),
        url: try args.require("url"),
        match: match,
        host: args.option("host"),
        query: try stringObjectOption(args.option("query"), name: "--query"),
        actions: actions
    )
}

/// Builds the action bundle from flags. The route is chosen by `--action`
/// (mock|block|mapRemote|passthrough); when omitted it defaults to `mapRemote` if
/// `--map-to` is present, otherwise `mock`. Modifiers (`--delay-ms`, header
/// rewrites, substitutions) compose with any route.
private func ruleActions(_ args: Args, ruleId: String) throws -> NetworkRuleActions {
    let inferred = args.option("map-to") != nil ? "mapRemote" : "mock"
    let action = (args.option("action") ?? inferred).lowercased()
    let route: NetworkRoute
    switch action {
    case "block":
        route = .block
    case "passthrough":
        route = .passthrough
    case "mapremote":
        let destination = try args.require("map-to")
        route = .mapRemote(NetworkMapRemote(
            destination: destination,
            keepHostHeader: args.option("keep-host-header") == "true"
        ))
    case "mock":
        route = .mock(valueId: args.option("value-id") ?? ruleId)
    default:
        throw HelperError("--action must be mock, block, mapRemote, or passthrough")
    }
    if let delay = args.option("delay-ms"), Int(delay) == nil {
        throw HelperError("--delay-ms must be an integer")
    }
    return NetworkRuleActions(
        route: route,
        delayMs: args.option("delay-ms").flatMap(Int.init),
        rewriteRequest: try headerRewrite(
            set: args.option("set-request-headers"),
            remove: args.option("remove-request-headers")
        ),
        rewriteResponse: try headerRewrite(
            set: args.option("set-response-headers"),
            remove: args.option("remove-response-headers")
        ),
        requestSubstitutions: try substitutions(args.option("request-subs"), name: "--request-subs"),
        responseSubstitutions: try substitutions(args.option("response-subs"), name: "--response-subs")
    )
}

private func headerRewrite(set: String?, remove: String?) throws -> NetworkHeaderRewrite? {
    let setHeaders = try stringObjectOption(set, name: "--set-*-headers") ?? [:]
    let removeHeaders = try stringArrayOption(remove, name: "--remove-*-headers") ?? []
    if setHeaders.isEmpty && removeHeaders.isEmpty { return nil }
    return NetworkHeaderRewrite(setHeaders: setHeaders, removeHeaders: removeHeaders)
}

private func substitutions(_ raw: String?, name: String) throws -> [NetworkSubstitution] {
    guard let raw, let data = raw.data(using: .utf8) else { return [] }
    do {
        return try JSONDecoder().decode([NetworkSubstitution].self, from: data)
    } catch {
        throw HelperError("\(name) must be a JSON array of substitutions ({field,match,replacement[,isRegex,caseSensitive]}): \(error)")
    }
}

private func valueRequest(_ args: Args, valueId: String) throws -> NetworkMockValueRequest {
    let body = try bodyOption(args)
    return NetworkMockValueRequest(
        id: valueId,
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

private func stringArrayOption(_ raw: String?, name: String) throws -> [String]? {
    guard let raw else { return nil }
    guard let data = raw.data(using: .utf8) else { return nil }
    let any = try JSONSerialization.jsonObject(with: data)
    guard let array = any as? [Any] else {
        throw HelperError("\(name) must be a JSON array of strings")
    }
    return array.map { "\($0)" }
}

private func bodyOption(_ args: Args) throws -> (text: String?, base64: String?) {
    if let body = args.option("body") { return (body, nil) }
    if let path = args.option("body-file") {
        return (nil, try Data(contentsOf: URL(fileURLWithPath: path)).base64EncodedString())
    }
    return (nil, nil)
}

private func exportRules(_ package: NetworkRuleExport, output: String?) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(package)
    if let output {
        try data.write(to: URL(fileURLWithPath: output), options: [.atomic])
        print("rule export: \(output)")
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private func importPackage(input: String) throws -> NetworkRuleExport {
    try JSONDecoder().decode(NetworkRuleExport.self, from: Data(contentsOf: URL(fileURLWithPath: input)))
}

private func printRules(_ rules: [NetworkRule]) {
    if rules.isEmpty {
        print("rules: none")
        return
    }
    print("rules:")
    for rule in rules {
        var qualifiers: [String] = []
        if let host = rule.host { qualifiers.append("host=\(host)") }
        if let query = rule.query, !query.isEmpty { qualifiers.append("query=\(query)") }
        let matcher = "\(rule.method) \(rule.match.rawValue) \(rule.url)"
        let suffix = qualifiers.isEmpty ? "" : " \(qualifiers.joined(separator: " "))"
        print("  \(rule.id) \(rule.enabled ? "on" : "off") priority=\(rule.priority) \(matcher)\(suffix) -> \(describe(rule.actions))")
    }
}

private func describe(_ actions: NetworkRuleActions) -> String {
    var parts: [String] = []
    switch actions.route {
    case .passthrough: parts.append("passthrough")
    case .block: parts.append("block")
    case .mock(let valueId): parts.append("mock(\(valueId))")
    case .mapRemote(let action): parts.append("mapRemote(\(action.destination))")
    }
    if let delay = actions.delayMs { parts.append("delay=\(delay)ms") }
    if actions.rewriteRequest?.isEmpty == false { parts.append("rewriteRequest") }
    if actions.rewriteResponse?.isEmpty == false { parts.append("rewriteResponse") }
    if !actions.requestSubstitutions.isEmpty { parts.append("reqSubs=\(actions.requestSubstitutions.count)") }
    if !actions.responseSubstitutions.isEmpty { parts.append("respSubs=\(actions.responseSubstitutions.count)") }
    return parts.joined(separator: " ")
}

private func printValues(_ values: [NetworkMockValue]) {
    if values.isEmpty {
        print("values: none")
        return
    }
    print("values:")
    for value in values {
        print("  \(value.id) status=\(value.status) contentType=\(value.contentType) bodyRef=\(value.bodyRef)")
    }
}

private final class DaemonRuleClient {
    private let baseURL: URL
    private let timeout: TimeInterval

    init(discovery: DaemonDiscovery = DaemonDiscovery(), timeout: TimeInterval = 2.0) throws {
        guard let info = discovery.readLive() else {
            throw HelperError("reticle serve is not running; start it before using reticle rule")
        }
        guard let baseURL = URL(string: "http://127.0.0.1:\(info.port)/sessions/current/") else {
            throw HelperError("invalid daemon URL")
        }
        self.baseURL = baseURL
        self.timeout = timeout
    }

    func rules() throws -> [NetworkRule] {
        try request("rules", method: "GET", response: NetworkRulesResponse.self).rules
    }

    func values() throws -> [NetworkMockValue] {
        try request("rules/values", method: "GET", response: NetworkMockValuesResponse.self).values
    }

    func exportPackage() throws -> NetworkRuleExport {
        try request("rules/export", method: "GET", response: NetworkRuleExport.self)
    }

    func importPackage(_ package: NetworkRuleExport) throws {
        let _: EmptyRuleResponse = try request("rules/import", method: "POST", body: package, response: EmptyRuleResponse.self)
    }

    func clear() throws {
        let _: EmptyRuleResponse = try request("rules/clear", method: "POST", response: EmptyRuleResponse.self)
    }

    func resolve(_ request: NetworkRuleResolveRequest) throws -> NetworkRuleResolveResponse {
        try self.request("rules/resolve", method: "POST", body: request, response: NetworkRuleResolveResponse.self)
    }

    func setRule(_ rule: NetworkRuleRequest) throws -> NetworkRule {
        try request("rules", method: "POST", body: rule, response: NetworkRule.self)
    }

    func enableRule(id: String) throws -> NetworkRule {
        try request("rules/\(encoded(id))/enable", method: "POST", response: NetworkRule.self)
    }

    func disableRule(id: String) throws -> NetworkRule {
        try request("rules/\(encoded(id))/disable", method: "POST", response: NetworkRule.self)
    }

    func removeRule(id: String) throws {
        try requestIgnoringBody("rules/\(encoded(id))", method: "DELETE")
    }

    func setValue(_ value: NetworkMockValueRequest) throws -> NetworkMockValue {
        try request("rules/values", method: "POST", body: value, response: NetworkMockValue.self)
    }

    func removeValue(id: String) throws {
        try requestIgnoringBody("rules/values/\(encoded(id))", method: "DELETE")
    }

    private func request<T: Decodable>(_ path: String, method: String, response: T.Type) throws -> T {
        try perform(path: path, method: method, body: Optional<Data>.none, response: response)
    }

    private func request<B: Encodable, T: Decodable>(_ path: String, method: String, body: B, response: T.Type) throws -> T {
        try perform(path: path, method: method, body: try JSONEncoder().encode(body), response: response)
    }

    private func requestIgnoringBody(_ path: String, method: String) throws {
        let _: EmptyRuleResponse = try perform(path: path, method: method, body: Optional<Data>.none, response: EmptyRuleResponse.self)
    }

    private func perform<T: Decodable>(path: String, method: String, body: Data?, response: T.Type) throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw HelperError("invalid daemon rule API path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<Data>(fallback: .failure(HelperError("daemon rule API returned no result")))
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
                box.set(.failure(HelperError("daemon rule API failed with HTTP \(status): \(message)")))
                return
            }
            box.set(.success(data))
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw HelperError("daemon rule API timed out")
        }
        return try JSONDecoder().decode(T.self, from: try box.value.get())
    }

    private func encoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

private struct EmptyRuleResponse: Decodable {}
