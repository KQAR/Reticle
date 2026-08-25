import Foundation
import LoomProxyCore
import LoomSharedModels
import Testing
@testable import ReticleNetworkLane

/// The rule-translation layer is the single most error-prone point in the capture
/// lane: Reticle matches a `/`-leading pattern against the URL *path*, Loom matches
/// the whole URL, and the lift between them is regex surgery on user-authored
/// patterns. It was also, until this suite, the one part of the lane with no unit
/// coverage at all — the `translate*` functions were exercised only by whichever
/// mock a device e2e happened to install.
///
/// Assertions go through `RuleMatch.matches(method:url:)` wherever they can, so what
/// is pinned is which URLs a translated rule accepts, not the spelling of the regex
/// it produced. A regex rewrite that preserves behavior should not fail these; one
/// that changes which traffic is mocked must.
@Suite("Loom rule translation")
struct LoomRuleTranslationTests {

    private func rule(
        id: String = "r",
        enabled: Bool = true,
        priority: Int = 0,
        method: String = "ANY",
        url: String,
        match: NetworkRuleMatch,
        host: String? = nil,
        query: [String: String]? = nil,
        actions: NetworkRuleActions = NetworkRuleActions(route: .block)
    ) -> NetworkRule {
        NetworkRule(
            id: id, enabled: enabled, priority: priority, method: method,
            url: url, match: match, host: host, query: query, actions: actions
        )
    }

    private func value(id: String = "v", status: Int = 200) -> NetworkMockExportValue {
        NetworkMockExportValue(
            id: id, status: status, headers: ["X-From": "mock"],
            contentType: "application/json",
            bodyBase64: Data(#"{"ok":true}"#.utf8).base64EncodedString()
        )
    }

    // MARK: - Path patterns lifted to whole-URL matches

    /// A path pattern must match that path under any origin, and must NOT match a URL
    /// where the path appears somewhere else — the failure mode of a naive lift, and
    /// the one that silently mocks a third party's traffic.
    @Test func anExactPathMatchesUnderAnyOriginAndNowhereElse() {
        let rules = LoomCaptureLane.translate(
            NetworkRuleExport(rules: [rule(url: "/v1/home", match: .exact)], values: [])
        )
        let match = try! #require(rules.first).match

        #expect(match.matches(method: "GET", url: "https://api.example.com/v1/home"))
        #expect(match.matches(method: "GET", url: "http://127.0.0.1:8080/v1/home"))
        // Exact means exact: a query is still the same resource, a longer path is not.
        #expect(match.matches(method: "GET", url: "https://api.example.com/v1/home?page=2"))
        #expect(!match.matches(method: "GET", url: "https://api.example.com/v1/home/extra"))
        #expect(!match.matches(method: "GET", url: "https://api.example.com/api?next=/v1/home"),
                "a path appearing in the QUERY is not the request's path")
        #expect(!match.matches(method: "GET", url: "https://api.example.com/proxy/v1/home"),
                "the lift anchors at the origin, so the path cannot match mid-URL")
    }

    @Test func aPrefixPathMatchesEverythingBeneathIt() {
        let rules = LoomCaptureLane.translate(
            NetworkRuleExport(rules: [rule(url: "/v1/", match: .prefix)], values: [])
        )
        let match = try! #require(rules.first).match

        #expect(match.matches(method: "GET", url: "https://api.example.com/v1/home"))
        #expect(match.matches(method: "POST", url: "https://api.example.com/v1/orders/7?x=1"))
        #expect(!match.matches(method: "GET", url: "https://api.example.com/v2/home"))
        #expect(!match.matches(method: "GET", url: "https://api.example.com/api/v1/home"),
                "a prefix is a prefix of the PATH, not of anything inside the URL")
    }

    /// A path pattern is escaped before it is lifted, so regex metacharacters in an
    /// exact/prefix pattern are literals — otherwise `/v1/a.b` would quietly match
    /// `/v1/axb` and a rule would fire on traffic its author never named.
    @Test func regexMetacharactersInAPathPatternAreLiterals() {
        let rules = LoomCaptureLane.translate(
            NetworkRuleExport(rules: [rule(url: "/v1/a.b", match: .exact)], values: [])
        )
        let match = try! #require(rules.first).match

        #expect(match.matches(method: "GET", url: "https://api.example.com/v1/a.b"))
        #expect(!match.matches(method: "GET", url: "https://api.example.com/v1/axb"))
    }

    /// A path pattern authored as a regex keeps its regex meaning, and its author's
    /// leading `^` — which anchors at the path, not at the URL — must not survive the
    /// lift, or the pattern can never match anything.
    @Test func aPathRegexKeepsItsMeaningAndLosesItsAnchor() {
        let rules = LoomCaptureLane.translate(
            NetworkRuleExport(rules: [rule(url: "^/v1/users/[0-9]+$", match: .regex)], values: [])
        )
        let match = try! #require(rules.first).match

        #expect(match.isRegex)
        #expect(match.matches(method: "GET", url: "https://api.example.com/v1/users/42"))
        #expect(!match.matches(method: "GET", url: "https://api.example.com/v1/users/me"))
    }

    /// The other half of that anchor rule: a regex over an ABSOLUTE url keeps its `^`,
    /// because there it anchors at the start of the URL Loom matches. Lifting it too
    /// would produce `origin-prefix` + `https://…`, which matches nothing.
    @Test func anAbsoluteUrlRegexKeepsItsAnchorAndIsNotLifted() {
        let rules = LoomCaptureLane.translate(NetworkRuleExport(
            rules: [rule(url: #"^https://api\.example\.com/v1/users/[0-9]+$"#, match: .regex)],
            values: []
        ))
        let match = try! #require(rules.first).match

        #expect(match.urlPattern == #"^https://api\.example\.com/v1/users/[0-9]+$"#)
        #expect(match.matches(method: "GET", url: "https://api.example.com/v1/users/42"))
        #expect(!match.matches(method: "GET", url: "https://other.example.com/v1/users/42"))
    }

    @Test func stripLeadingCaretOnlyTouchesALeadingCaret() {
        #expect(LoomCaptureLane.stripLeadingCaret("^/a") == "/a")
        #expect(LoomCaptureLane.stripLeadingCaret("/a^b") == "/a^b")
        #expect(LoomCaptureLane.stripLeadingCaret("") == "")
    }

    /// The divergence this suite was written to catch, stated as one assertion: the
    /// store's own matcher (what `rule resolve` answers with) and the engine's matcher
    /// (what actually reshapes traffic) must agree. They did not for an anchored path
    /// regex — `resolve` reported the rule as matching while the translated pattern
    /// could match no URL at all, so a mock reported as active never fired.
    @Test func resolveAndTheEngineAgreeOnAnAnchoredPathRegex() throws {
        let session = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("reticle-rule-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: session) }
        let store = try NetworkRuleStore(sessionDirectory: session)
        _ = try store.upsertRule(NetworkRuleRequest(
            id: "users", enabled: true, priority: 0, method: "GET",
            url: #"^/v1/users/[0-9]+$"#, match: .regex,
            actions: NetworkRuleActions(route: .block)
        ))

        let url = "https://api.example.com/v1/users/42"
        let resolved = try store.resolve(NetworkRuleRequestContext(method: "GET", url: url, path: "/v1/users/42"))
        #expect(resolved?.rule.id == "users", "the store's own matcher accepts an anchored path regex")

        let translated = LoomCaptureLane.translate(try store.exportPackage())
        // ...and so must the pattern the engine is given, or `rule resolve` reports a
        // rule that can never fire.
        #expect(try! #require(translated.first).match.matches(method: "GET", url: url))
    }

    // MARK: - Absolute-URL patterns pass through

    /// An absolute pattern is already in Loom's vocabulary, so it must be handed over
    /// unlifted — wrapping it in the origin prefix would make it unmatchable.
    @Test func anAbsoluteUrlPatternIsNotLifted() {
        let exact = LoomCaptureLane.translate(
            NetworkRuleExport(rules: [rule(url: "https://api.example.com/v1/home", match: .exact)], values: [])
        )
        let exactMatch = try! #require(exact.first).match
        #expect(exactMatch.isExact)
        #expect(!exactMatch.isRegex)
        #expect(exactMatch.matches(method: "GET", url: "https://api.example.com/v1/home"))
        #expect(!exactMatch.matches(method: "GET", url: "https://other.example.com/v1/home"))

        let prefix = LoomCaptureLane.translate(
            NetworkRuleExport(rules: [rule(url: "https://api.example.com/v1", match: .prefix)], values: [])
        )
        let prefixMatch = try! #require(prefix.first).match
        #expect(!prefixMatch.isRegex)
        #expect(!prefixMatch.isExact, "Loom's plain pattern is already a prefix match")
        #expect(prefixMatch.matches(method: "GET", url: "https://api.example.com/v1/home"))
    }

    // MARK: - Method, host and query predicates

    @Test func anyMethodBecomesNoMethodConstraint() {
        let any = LoomCaptureLane.translate(
            NetworkRuleExport(rules: [rule(method: "ANY", url: "/v1", match: .prefix)], values: [])
        )
        #expect(try! #require(any.first).match.methods.isEmpty,
                "ANY must mean unconstrained, not a literal method named ANY")

        let post = LoomCaptureLane.translate(
            NetworkRuleExport(rules: [rule(method: "POST", url: "/v1", match: .prefix)], values: [])
        )
        let match = try! #require(post.first).match
        #expect(match.methods == ["POST"])
        #expect(match.matches(method: "POST", url: "https://api.example.com/v1/x"))
        #expect(!match.matches(method: "GET", url: "https://api.example.com/v1/x"))
    }

    @Test func hostAndQueryPredicatesAreCarriedThrough() {
        let rules = LoomCaptureLane.translate(NetworkRuleExport(
            rules: [rule(url: "/v1", match: .prefix, host: "*.example.com", query: ["debug": "1"])],
            values: []
        ))
        let match = try! #require(rules.first).match

        #expect(match.hostPattern == "*.example.com")
        #expect(match.query == ["debug": "1"])
        #expect(match.matches(method: "GET", url: "https://api.example.com/v1/x?debug=1"))
        #expect(!match.matches(method: "GET", url: "https://api.example.com/v1/x?debug=0"))
        #expect(!match.matches(method: "GET", url: "https://api.elsewhere.net/v1/x?debug=1"))
    }

    // MARK: - Ordering, identity, and what gets dropped

    /// Loom applies the first matching rule, and Reticle's precedence is by descending
    /// priority. If the sort ever inverts, the wrong mock wins on any screen with two
    /// overlapping rules — a bug that looks like a mock "not working".
    @Test func rulesAreHandedOverHighestPriorityFirst() {
        let rules = LoomCaptureLane.translate(NetworkRuleExport(
            rules: [
                rule(id: "low", priority: 1, url: "/v1", match: .prefix),
                rule(id: "high", priority: 9, url: "/v1", match: .prefix),
                rule(id: "mid", priority: 5, url: "/v1", match: .prefix)
            ],
            values: []
        ))

        #expect(rules.map(\.name) == ["high", "mid", "low"])
    }

    /// The Loom rule name carries the Reticle rule id, which is what makes an applied
    /// rule attributable back on the captured flow (`ruleId` on the event).
    @Test func theLoomRuleNameIsTheReticleRuleId() {
        let rules = LoomCaptureLane.translate(
            NetworkRuleExport(rules: [rule(id: "checkout-500", url: "/pay", match: .prefix)], values: [])
        )
        #expect(rules.map(\.name) == ["checkout-500"])
    }

    /// A disabled rule still crosses over — Loom owns the enabled flag, so dropping it
    /// here would make "disable" indistinguishable from "delete" in the engine and a
    /// re-enable would need a full resync to take effect.
    @Test func aDisabledRuleIsTranslatedAsDisabledRatherThanDropped() {
        let rules = LoomCaptureLane.translate(
            NetworkRuleExport(rules: [rule(enabled: false, url: "/v1", match: .prefix)], values: [])
        )
        #expect(rules.count == 1)
        #expect(try! #require(rules.first).isEnabled == false)
    }

    /// A no-op rule (passthrough, no modifiers) is dropped here rather than handed to
    /// Loom, which rejects a rule with no actions — a rejection report full of rules
    /// that carry no behavior anyway is a report nobody reads.
    @Test func noOpPassthroughRulesAreDroppedBeforeTheEngineRejectsThem() {
        let rules = LoomCaptureLane.translate(NetworkRuleExport(
            rules: [
                rule(id: "noop", url: "/v1", match: .prefix, actions: NetworkRuleActions(route: .passthrough)),
                rule(id: "delayed", url: "/v2", match: .prefix,
                     actions: NetworkRuleActions(route: .passthrough, delayMs: 250))
            ],
            values: []
        ))

        #expect(rules.map(\.name) == ["delayed"],
                "a passthrough WITH a modifier is behavior; one without is not")
    }

    /// A mock whose value is gone is dropped for the same reason: handing it over would
    /// produce an engine rejection, and mocking with no body is not a safer guess.
    @Test func aMockReferencingAMissingValueIsDropped() {
        let rules = LoomCaptureLane.translate(NetworkRuleExport(
            rules: [
                rule(id: "orphan", url: "/a", match: .prefix, actions: NetworkRuleActions(route: .mock(valueId: "gone"))),
                rule(id: "kept", url: "/b", match: .prefix, actions: NetworkRuleActions(route: .mock(valueId: "v")))
            ],
            values: [value()]
        ))

        #expect(rules.map(\.name) == ["kept"])
    }

    /// A dropped rule must be nameable. The store accepts a mock authored before its
    /// value, and this lane then drops it — so without a reason to print, an agent gets
    /// a `201` and live traffic, with nothing anywhere saying why.
    @Test func everyDroppedRuleHasAReasonToPrint() {
        let export = NetworkRuleExport(
            rules: [
                rule(id: "noop", url: "/a", match: .prefix, actions: NetworkRuleActions(route: .passthrough)),
                rule(id: "orphan", url: "/b", match: .prefix, actions: NetworkRuleActions(route: .mock(valueId: "gone"))),
                rule(id: "kept", url: "/c", match: .prefix)
            ],
            values: []
        )
        let translated = LoomCaptureLane.translate(export)
        let dropped = LoomCaptureLane.droppedRuleReasons(export, translated: translated)

        #expect(dropped.map(\.id) == ["noop", "orphan"])
        #expect(dropped.first { $0.id == "noop" }?.reason.contains("changes nothing") == true)
        // The reason has to be actionable, not just true.
        let orphanReason = dropped.first { $0.id == "orphan" }?.reason ?? ""
        #expect(orphanReason.contains("gone"))
        #expect(orphanReason.contains("create the value"))
        #expect(LoomCaptureLane.droppedRuleReasons(nil, translated: []).isEmpty)
    }

    @Test func noExportMeansNoRules() {
        #expect(LoomCaptureLane.translate(nil).isEmpty)
    }

    // MARK: - Routes

    @Test func mockRoutesCarryTheValuesFieldsVerbatim() {
        let route = LoomCaptureLane.translateRoute(
            .mock(valueId: "v"), valuesById: ["v": value(status: 503)]
        )
        guard case .mock(let action)? = route else {
            Issue.record("expected a mock route, got \(String(describing: route))")
            return
        }
        #expect(action.statusCode == 503)
        #expect(action.contentType == "application/json")
        #expect(action.headers.contains { $0.name == "X-From" && $0.value == "mock" })
        #expect(Data(base64Encoded: action.bodyBase64 ?? "") == Data(#"{"ok":true}"#.utf8))
    }

    @Test func blockAndPassthroughAndMapRemoteMapOneToOne() {
        #expect(LoomCaptureLane.translateRoute(.block, valuesById: [:]) == .block)
        #expect(LoomCaptureLane.translateRoute(.passthrough, valuesById: [:]) == .passthrough)

        let mapped = LoomCaptureLane.translateRoute(
            .mapRemote(NetworkMapRemote(destination: "https://staging.example.com", keepHostHeader: true)),
            valuesById: [:]
        )
        guard case .mapRemote(let action)? = mapped else {
            Issue.record("expected a mapRemote route, got \(String(describing: mapped))")
            return
        }
        #expect(action.destination == "https://staging.example.com")
        #expect(action.keepHostHeader)
    }

    // MARK: - Modifiers

    /// An empty rewrite must translate to *no* rewrite rather than an empty one: a
    /// rewrite action that sets and removes nothing is behavior the engine has to
    /// evaluate on every flow for no effect.
    @Test func emptyHeaderRewritesBecomeNoRewriteAtAll() {
        #expect(LoomCaptureLane.translateRewriteRequest(nil) == nil)
        #expect(LoomCaptureLane.translateRewriteRequest(NetworkHeaderRewrite()) == nil)
        #expect(LoomCaptureLane.translateRewriteResponse(nil) == nil)
        #expect(LoomCaptureLane.translateRewriteResponse(NetworkHeaderRewrite()) == nil)
    }

    @Test func headerRewritesCarryBothDirections() {
        let request = LoomCaptureLane.translateRewriteRequest(
            NetworkHeaderRewrite(setHeaders: ["X-Env": "staging"], removeHeaders: ["Cookie"])
        )
        #expect(request?.setHeaders.contains { $0.name == "X-Env" && $0.value == "staging" } == true)
        #expect(request?.removeHeaders == ["Cookie"])

        let response = LoomCaptureLane.translateRewriteResponse(
            NetworkHeaderRewrite(setHeaders: ["Cache-Control": "no-store"], removeHeaders: [])
        )
        #expect(response?.setHeaders.contains { $0.name == "Cache-Control" } == true)
        #expect(response?.removeHeaders.isEmpty == true)
    }

    /// The substitution field is an enum on both sides, so a mis-mapped case would send
    /// a body substitution at the URL — silently, since both are strings.
    @Test func substitutionFieldsMapCaseForCase() {
        let expected: [NetworkSubstitution.Field: SubstitutionRule.Field] = [
            .url: .url, .header: .header, .body: .body
        ]
        for (reticle, loom) in expected {
            let translated = LoomCaptureLane.translateSubstitution(NetworkSubstitution(
                field: reticle, match: "a", replacement: "b", isRegex: true, caseSensitive: true
            ))
            #expect(translated.field == loom)
            #expect(translated.match == "a")
            #expect(translated.replacement == "b")
            #expect(translated.isRegex)
            #expect(translated.caseSensitive)
        }
        #expect(NetworkSubstitution.Field.allCases.count == expected.count,
                "a new substitution field needs a mapping and a case here")
    }

    @Test func delayAndSubstitutionsRideAlongWithTheRoute() {
        let rules = LoomCaptureLane.translate(NetworkRuleExport(
            rules: [rule(url: "/v1", match: .prefix, actions: NetworkRuleActions(
                route: .block,
                delayMs: 750,
                rewriteRequest: NetworkHeaderRewrite(setHeaders: ["X-Test": "1"]),
                requestSubstitutions: [NetworkSubstitution(field: .body, match: "a", replacement: "b")],
                responseSubstitutions: [NetworkSubstitution(field: .header, match: "c", replacement: "d")]
            ))],
            values: []
        ))
        let actions = try! #require(rules.first).actions

        #expect(actions.delayMilliseconds == 750)
        #expect(actions.rewriteRequest != nil)
        #expect(actions.rewriteResponse == nil)
        #expect(actions.requestSubstitutions.count == 1)
        #expect(actions.responseSubstitutions.count == 1)
    }

    // MARK: - Flow filters

    /// The filter is a straight field-for-field carry, and that is exactly why it is
    /// worth pinning: a dropped field silently widens a query, which reads as "the flow
    /// I wanted isn't there" rather than as a bug.
    @Test func everyFilterFieldReachesTheEngineQuery() {
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let query = LoomCaptureLane.translateFilter(NetworkFlowFilter(
            host: "api.example.com",
            methods: ["GET", "POST"],
            urlContains: "/checkout",
            statusMin: 400,
            statusMax: 599,
            onlyErrors: true,
            since: since,
            headerContains: "authorization",
            bodyContains: "orderId",
            limit: 10
        ))

        #expect(query.host == "api.example.com")
        #expect(query.methods == ["GET", "POST"])
        #expect(query.urlContains == "/checkout")
        #expect(query.statusMin == 400)
        #expect(query.statusMax == 599)
        #expect(query.onlyErrors)
        #expect(query.since == since)
        #expect(query.headerContains == "authorization")
        #expect(query.bodyContains == "orderId")
    }
}
