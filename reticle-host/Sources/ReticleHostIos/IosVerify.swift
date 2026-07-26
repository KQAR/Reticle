import Foundation
import ReticleHostShared
import ReticleProtocol

// `act --verify` on iOS: capture the watched node's state before the gesture, poll
// it after, and report the same `verify` result shape the Android helper produces
// (which is what makes the host's `printVerify` platform-agnostic).
//
// Split out of `IosHelperClient` for the same reason as the scroll-to half.
extension IosHelperClient {
    // MARK: - Verify (act --verify)

    struct VerifyState {
        let found: Bool
        let text: String?
        let label: String?
        let enabled: Bool
        let visible: Bool
        let frame: String?
        let custom: [String: String]
    }

    /// Resolves the `--verify` token into the node selector to watch, or nil when
    /// verify is off. Mirrors the Android helper's `parseVerifyToken` grammar so both
    /// platforms accept the same spellings (`#id`/`testId=`/`@id`/`resourceId=`/
    /// `css=`/`ref=`/bare ref, plus `true` = watch the acted-on selector).
    func verifyWatchSelector(_ params: [String: Any]) throws -> TargetSelector? {
        let token: String
        if let s = params["verify"] as? String { token = s }
        else if let b = params["verify"] as? Bool { token = b ? "true" : "false" }
        else { return nil }
        return try IosHelperClient.parseVerifyToken(token, actSelector: selectorFromParams(params))
    }

    /// Resolves a `--verify` token into the node selector to watch. Pure and
    /// `internal` so it can be unit-tested without a device, mirroring the Android
    /// helper's `parseVerifyToken` (and its `VerifyTokenTest`) grammar 1:1 — this
    /// exact grammar silently regressed on Android once, so it stays test-guarded.
    static func parseVerifyToken(_ token: String, actSelector: ReticleProtocol.Selector) throws -> ReticleProtocol.Selector? {
        switch token {
        case "false":
            return nil
        case "true":
            let s = actSelector
            if s.testId == nil && s.resourceId == nil && s.cssSelector == nil && s.ref == nil {
                throw HelperError("--verify needs a node selector to watch: pass --verify <#testId|testId=<id>|@resourceId|resourceId=<id>|css=<selector>|ref>, or act by selector rather than --point")
            }
            return ReticleProtocol.Selector(testId: s.testId, resourceId: s.resourceId, cssSelector: s.cssSelector, ref: s.ref)
        default:
            if token.hasPrefix("#") { return ReticleProtocol.Selector(testId: String(token.dropFirst())) }
            if token.hasPrefix("@") { return ReticleProtocol.Selector(resourceId: String(token.dropFirst())) }
            if token.hasPrefix("css=") { return ReticleProtocol.Selector(cssSelector: String(token.dropFirst("css=".count))) }
            if token.hasPrefix("testId=") { return ReticleProtocol.Selector(testId: String(token.dropFirst("testId=".count))) }
            if token.hasPrefix("resourceId=") { return ReticleProtocol.Selector(resourceId: String(token.dropFirst("resourceId=".count))) }
            if token.hasPrefix("ref=") { return ReticleProtocol.Selector(ref: String(token.dropFirst("ref=".count))) }
            if token.contains("=") {
                throw HelperError("unrecognized --verify selector '\(token)': use #<testId>, testId=<id>, @<resourceId>, resourceId=<id>, css=<selector>, ref=<ref>, or a bare ref")
            }
            return ReticleProtocol.Selector(ref: token)
        }
    }

    /// Captures the watched node's current state, or a not-found state when the
    /// selector resolves nothing. A snapshot fetch failure reads as not-found —
    /// verify never fails the action it wraps.
    func captureVerifyState(_ pkg: String, _ selector: TargetSelector) -> VerifyState {
        guard let snapshot = try? fetchSnapshot(pkg), let node = Render.findNode(snapshot, selector) else {
            return VerifyState(found: false, text: nil, label: nil, enabled: false, visible: false, frame: nil, custom: [:])
        }
        let frame = node.frame.map { "\(Int($0.x)),\(Int($0.y)) \(Int($0.width))x\(Int($0.height))" }
        return VerifyState(
            found: true,
            text: node.text,
            label: node.contentDescription,
            enabled: node.isEnabled,
            visible: node.isVisible,
            frame: frame,
            custom: node.custom.mapValues { $0.displayString() }
        )
    }

    /// Polls the watched node until it differs from `before` or the budget expires,
    /// returning the `{selector, changed, note?, changes[]}` shape `printVerify` reads.
    func pollVerify(_ pkg: String, _ selector: TargetSelector, before: VerifyState, params: [String: Any]) -> [String: Any] {
        let budgetMs = (params["verifyTimeoutMs"] as? Int)
            ?? (params["verifyTimeoutMs"] as? Double).map(Int.init)
            ?? 2000
        let deadline = Date().addingTimeInterval(Double(budgetMs) / 1000.0)
        var after = captureVerifyState(pkg, selector)
        var changes = diffVerify(before, after)
        while changes.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.15)
            after = captureVerifyState(pkg, selector)
            changes = diffVerify(before, after)
        }
        let selStr: String
        if let t = selector.testId { selStr = "#\(t)" }
        else if let r = selector.resourceId { selStr = "@\(r)" }
        else if let c = selector.cssSelector { selStr = "css=\(c)" }
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

    func diffVerify(_ before: VerifyState, _ after: VerifyState) -> [(field: String, before: String?, after: String?)] {
        var out: [(field: String, before: String?, after: String?)] = []
        if before.found != after.found { out.append((field: "present", before: String(before.found), after: String(after.found))) }
        if before.text != after.text { out.append((field: "text", before: before.text, after: after.text)) }
        if before.label != after.label { out.append((field: "label", before: before.label, after: after.label)) }
        if before.enabled != after.enabled { out.append((field: "enabled", before: String(before.enabled), after: String(after.enabled))) }
        if before.visible != after.visible { out.append((field: "visible", before: String(before.visible), after: String(after.visible))) }
        if before.frame != after.frame { out.append((field: "frame", before: before.frame, after: after.frame)) }
        for key in Set(before.custom.keys).union(after.custom.keys).sorted() {
            let b = before.custom[key]
            let a = after.custom[key]
            if b != a { out.append((field: key, before: b, after: a)) }
        }
        return out
    }
}
