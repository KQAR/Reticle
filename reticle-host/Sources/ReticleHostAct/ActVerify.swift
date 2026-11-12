import Foundation
import ReticleHostShared
import ReticleProtocol

/// `act --verify`: capture the watched node's state before the gesture, poll it
/// after, and report the `verify` result shape the host's `printVerify` renders —
/// for both platforms (the Kotlin `HelperVerify` went with #326).
public enum ActVerify {
    public struct State {
        let found: Bool
        let text: String?
        let label: String?
        let enabled: Bool
        let visible: Bool
        let frame: String?
        /// Toggle and disclosure state — the two things a tap on a checkbox or a
        /// dropdown changes and nothing else here records. See the Kotlin twin for
        /// the consent screen where a ticked box reported only a css-class change.
        let checked: String?
        let expanded: String?
        let custom: [String: String]
    }

    /// Resolves the `--verify` token into the node selector to watch, or nil when
    /// verify is off. Mirrors the Android helper's `parseVerifyToken` grammar so both
    /// platforms accept the same spellings (`#id`/`testId=`/`@id`/`resourceId=`/
    /// `css=`/`ref=`/bare ref, plus `true` = watch the acted-on selector).
    public static func watchSelector(_ params: [String: Any]) throws -> ReticleProtocol.Selector? {
        let token: String
        if let s = params["verify"] as? String { token = s }
        else if let b = params["verify"] as? Bool { token = b ? "true" : "false" }
        else { return nil }
        return try parseToken(token, actSelector: ActParams.selector(params))
    }

    /// Resolves a `--verify` token into the node selector to watch. Pure and
    /// `internal` so it can be unit-tested without a device, mirroring the Android
    /// helper's `parseVerifyToken` (and its `VerifyTokenTest`) grammar 1:1 — this
    /// exact grammar silently regressed on Android once, so it stays test-guarded.
    public static func parseToken(_ token: String, actSelector: ReticleProtocol.Selector) throws -> ReticleProtocol.Selector? {
        switch token {
        case "false":
            return nil
        case "true":
            let s = actSelector
            // `--label` counts: it is a node selector like any other, and bare
            // `--verify` used to refuse it while the caller WAS acting by selector.
            if s.testId == nil && s.resourceId == nil && s.cssSelector == nil && s.ref == nil
                && s.label == nil
            {
                throw HelperError("--verify needs a node selector to watch: pass --verify <#testId|testId=<id>|@resourceId|resourceId=<id>|css=<selector>|label=<text>|ref>, or act by selector rather than --point")
            }
            return ReticleProtocol.Selector(
                testId: s.testId, resourceId: s.resourceId, cssSelector: s.cssSelector,
                ref: s.ref, label: s.label
            )
        default:
            if token.hasPrefix("#") { return ReticleProtocol.Selector(testId: String(token.dropFirst())) }
            if token.hasPrefix("@") { return ReticleProtocol.Selector(resourceId: String(token.dropFirst())) }
            if token.hasPrefix("css=") { return ReticleProtocol.Selector(cssSelector: String(token.dropFirst("css=".count))) }
            if token.hasPrefix("testId=") { return ReticleProtocol.Selector(testId: String(token.dropFirst("testId=".count))) }
            if token.hasPrefix("resourceId=") { return ReticleProtocol.Selector(resourceId: String(token.dropFirst("resourceId=".count))) }
            if token.hasPrefix("ref=") { return ReticleProtocol.Selector(ref: String(token.dropFirst("ref=".count))) }
            if token.hasPrefix("label=") { return ReticleProtocol.Selector(label: String(token.dropFirst("label=".count))) }
            if token.contains("=") {
                throw HelperError("unrecognized --verify selector '\(token)': use #<testId>, testId=<id>, @<resourceId>, resourceId=<id>, css=<selector>, label=<text>, ref=<ref>, or a bare ref")
            }
            return ReticleProtocol.Selector(ref: token)
        }
    }

    /// Captures the watched node's current state, or a not-found state when the
    /// selector resolves nothing. A snapshot fetch failure reads as not-found —
    /// verify never fails the action it wraps.
    public static func capture(_ selector: ReticleProtocol.Selector, fetch: SnapshotFetch) async -> State {
        guard let snapshot = try? await fetch(), let node = try? Render.findNode(snapshot, selector) else {
            return State(
                found: false, text: nil, label: nil, enabled: false, visible: false, frame: nil,
                checked: nil, expanded: nil, custom: [:]
            )
        }
        let frame = node.frame.map(\.intDescription)
        return State(
            found: true,
            text: node.text,
            label: node.contentDescription,
            enabled: node.isEnabled,
            visible: node.isVisible,
            frame: frame,
            checked: node.checked?.rawValue,
            expanded: node.expanded.map(String.init),
            custom: node.custom.mapValues { $0.displayString() }
        )
    }

    /// Polls the watched node until it differs from `before` or the budget expires,
    /// returning the `{selector, changed, note?, changes[]}` shape `printVerify` reads.
    public static func poll(
        _ selector: ReticleProtocol.Selector, before: State, params: [String: Any], fetch: SnapshotFetch
    ) async -> [String: Any] {
        let budgetMs = (params["verifyTimeoutMs"] as? Int)
            ?? (params["verifyTimeoutMs"] as? Double).map(Int.init)
            ?? 2000
        let deadline = Date().addingTimeInterval(Double(budgetMs) / 1000.0)
        var after = await capture(selector, fetch: fetch)
        var changes = diff(before, after)
        while changes.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .seconds(0.15))
            after = await capture(selector, fetch: fetch)
            changes = diff(before, after)
        }
        let selStr: String
        if let t = selector.testId { selStr = "#\(t)" }
        else if let r = selector.resourceId { selStr = "@\(r)" }
        else if let c = selector.cssSelector { selStr = "css=\(c)" }
        else if let l = selector.label { selStr = "label=\(l)" }
        else if let r = selector.ref { selStr = r }
        else { selStr = "?" }
        var out: [String: Any] = ["selector": selStr, "changed": !changes.isEmpty]
        if !after.found { out["note"] = "node not present after action" }
        out["changes"] = changes.map { change -> [String: Any] in
            var c: [String: Any] = ["field": change.field]
            if let b = change.before { c["before"] = b }
            if let a = change.after { c["after"] = a }
            return c
        }
        return out
    }

    static func diff(_ before: State, _ after: State) -> [(field: String, before: String?, after: String?)] {
        var out: [(field: String, before: String?, after: String?)] = []
        if before.found != after.found { out.append((field: "present", before: String(before.found), after: String(after.found))) }
        if before.text != after.text { out.append((field: "text", before: before.text, after: after.text)) }
        if before.label != after.label { out.append((field: "label", before: before.label, after: after.label)) }
        if before.enabled != after.enabled { out.append((field: "enabled", before: String(before.enabled), after: String(after.enabled))) }
        if before.visible != after.visible { out.append((field: "visible", before: String(before.visible), after: String(after.visible))) }
        if before.frame != after.frame { out.append((field: "frame", before: before.frame, after: after.frame)) }
        if before.checked != after.checked { out.append((field: "checked", before: before.checked, after: after.checked)) }
        if before.expanded != after.expanded { out.append((field: "expanded", before: before.expanded, after: after.expanded)) }
        for key in Set(before.custom.keys).union(after.custom.keys).sorted() {
            let b = before.custom[key]
            let a = after.custom[key]
            if b != a { out.append((field: key, before: b, after: a)) }
        }
        return out
    }
}
