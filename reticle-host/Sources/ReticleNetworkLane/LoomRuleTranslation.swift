import Foundation
import LoomProxyCore
import LoomSharedModels
import ReticleHostShared

// Reticle's traffic rules and flow filters, translated into Loom's engine types.
//
// Split out of `LoomCaptureLane` because it is the one part of the lane that is
// pure: no engine, no lock, no cursor — a total function from Reticle's rule/filter
// model to Loom's. That makes it the part worth reading (and unit-testing) on its
// own, and it kept the capture path's own 700 lines from being read past to reach
// it. The members are `static` rather than `private static` only because a Swift
// extension in another file cannot see `private`; nothing outside this module can
// reach them.
extension LoomCaptureLane {
    // MARK: - Rule translation

    /// Translates Reticle's traffic rules + values into Loom `TrafficRule`s. The Loom
    /// rule name carries the Reticle rule id so an applied rule is attributable back on
    /// the captured flow. Rules are ordered by descending priority to match Reticle's
    /// precedence (Loom applies the first matching rule). No-op rules (passthrough with
    /// no modifiers) are dropped here rather than handed over to fail Loom's "rule has
    /// no actions" validation — they carry no behavior either way, and dropping them
    /// keeps the engine's rejection report meaningful. A `mock` route whose referenced
    /// value is missing is dropped for the same reason.
    static func translate(_ export: NetworkRuleExport?) -> [TrafficRule] {
        guard let export else { return [] }
        let valuesById = Dictionary(export.values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return export.rules
            .filter { !$0.actions.isNoOp }
            .sorted { $0.priority > $1.priority }
            .compactMap { rule in
                guard let route = translateRoute(rule.actions.route, valuesById: valuesById) else { return nil }
                let actions = RuleActions(
                    route: route,
                    rewriteRequest: translateRewriteRequest(rule.actions.rewriteRequest),
                    rewriteResponse: translateRewriteResponse(rule.actions.rewriteResponse),
                    requestSubstitutions: rule.actions.requestSubstitutions.map(translateSubstitution),
                    responseSubstitutions: rule.actions.responseSubstitutions.map(translateSubstitution),
                    delayMilliseconds: rule.actions.delayMs
                )
                return TrafficRule(
                    name: rule.id,
                    isEnabled: rule.enabled,
                    match: translateMatch(rule),
                    actions: actions
                )
            }
    }

    /// Why each rule in `export` is missing from `translated`, for the sync path to
    /// report. Derived by comparing the two rather than threaded out of `translate`,
    /// which stays a pure total function — and derived from the SAME predicates
    /// `translate` filters on, so a new drop reason cannot be added there without a
    /// name for it here.
    static func droppedRuleReasons(
        _ export: NetworkRuleExport?,
        translated: [TrafficRule]
    ) -> [(id: String, reason: String)] {
        guard let export else { return [] }
        let kept = Set(translated.map(\.name))
        let valueIds = Set(export.values.map(\.id))
        return export.rules.filter { !kept.contains($0.id) }.map { rule in
            if rule.actions.isNoOp {
                return (rule.id, "it changes nothing (a passthrough route with no modifiers), "
                    + "so it was not handed to the capture engine")
            }
            if let valueId = rule.mockValueId, !valueIds.contains(valueId) {
                return (rule.id, "its mock response value \(valueId) does not exist — "
                    + "create the value, then re-apply the rule")
            }
            return (rule.id, "it was dropped before reaching the capture engine")
        }
    }

    /// Maps a Reticle route onto Loom's. Returns nil to drop the rule when a `mock`
    /// route references a value that isn't in the export.
    static func translateRoute(_ route: NetworkRoute, valuesById: [String: NetworkMockExportValue]) -> Route? {
        switch route {
        case .passthrough:
            return .passthrough
        case .block:
            return .block
        case .mock(let valueId):
            guard let value = valuesById[valueId] else { return nil }
            return .mock(MockResponseAction(
                statusCode: value.status,
                headers: value.headers.map { HeaderPair(name: $0.key, value: $0.value) },
                bodyBase64: value.bodyBase64,
                contentType: value.contentType
            ))
        case .mapRemote(let action):
            return .mapRemote(MapRemoteAction(destination: action.destination, keepHostHeader: action.keepHostHeader))
        }
    }

    static func translateRewriteRequest(_ rewrite: NetworkHeaderRewrite?) -> RequestRewriteAction? {
        guard let rewrite, !rewrite.isEmpty else { return nil }
        return RequestRewriteAction(
            setHeaders: rewrite.setHeaders.map { HeaderPair(name: $0.key, value: $0.value) },
            removeHeaders: rewrite.removeHeaders
        )
    }

    static func translateRewriteResponse(_ rewrite: NetworkHeaderRewrite?) -> ResponseRewriteAction? {
        guard let rewrite, !rewrite.isEmpty else { return nil }
        return ResponseRewriteAction(
            setHeaders: rewrite.setHeaders.map { HeaderPair(name: $0.key, value: $0.value) },
            removeHeaders: rewrite.removeHeaders
        )
    }

    static func translateSubstitution(_ substitution: NetworkSubstitution) -> SubstitutionRule {
        let field: SubstitutionRule.Field
        switch substitution.field {
        case .url: field = .url
        case .header: field = .header
        case .body: field = .body
        }
        return SubstitutionRule(
            field: field,
            match: substitution.match,
            replacement: substitution.replacement,
            isRegex: substitution.isRegex,
            caseSensitive: substitution.caseSensitive
        )
    }

    static func translateMatch(_ rule: NetworkRule) -> RuleMatch {
        let methods = rule.method == "ANY" ? [] : [rule.method]
        let host = rule.host
        let query = rule.query
        // Reticle matches a `/`-leading pattern against the URL path; Loom matches
        // the full URL, so a path pattern is lifted to a regex that skips the
        // scheme+authority prefix.
        //
        // A regex is tested for path-ness AFTER its leading `^` is dropped. Anchoring
        // a path regex at the path is the natural way to write one (`^/v1/users/\d+$`),
        // and reading the caret as part of the pattern made such a rule "absolute":
        // handed to Loom verbatim, anchored at the start of a URL that begins with a
        // scheme, so it could never match anything. A rule that matches nothing looks
        // exactly like a mock that "doesn't work".
        let isPath = rule.match == .regex
            ? stripLeadingCaret(rule.url).hasPrefix("/")
            : rule.url.hasPrefix("/")
        let originPrefix = "^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+"

        switch rule.match {
        case .regex:
            let pattern = isPath ? originPrefix + stripLeadingCaret(rule.url) : rule.url
            return RuleMatch(urlPattern: pattern, isRegex: true, methods: methods, hostPattern: host, query: query)
        case .exact:
            if isPath {
                let pattern = originPrefix + NSRegularExpression.escapedPattern(for: rule.url) + "(\\?.*)?$"
                return RuleMatch(urlPattern: pattern, isRegex: true, methods: methods, hostPattern: host, query: query)
            }
            return RuleMatch(urlPattern: rule.url, methods: methods, isExact: true, hostPattern: host, query: query)
        case .prefix:
            if isPath {
                let pattern = originPrefix + NSRegularExpression.escapedPattern(for: rule.url)
                return RuleMatch(urlPattern: pattern, isRegex: true, methods: methods, hostPattern: host, query: query)
            }
            // Loom's non-regex, non-exact pattern is a prefix match by default.
            return RuleMatch(urlPattern: rule.url, methods: methods, hostPattern: host, query: query)
        }
    }

    static func stripLeadingCaret(_ pattern: String) -> String {
        pattern.hasPrefix("^") ? String(pattern.dropFirst()) : pattern
    }
    static func translateFilter(_ filter: NetworkFlowFilter) -> FlowQuery {
        FlowQuery(
            host: filter.host,
            methods: filter.methods,
            urlContains: filter.urlContains,
            statusMin: filter.statusMin,
            statusMax: filter.statusMax,
            onlyErrors: filter.onlyErrors,
            since: filter.since,
            headerContains: filter.headerContains,
            bodyContains: filter.bodyContains
        )
    }
}
