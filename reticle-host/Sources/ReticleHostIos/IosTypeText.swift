import Foundation
import ReticleHostShared
import ReticleProtocol

// Typing on iOS: the in-process `/type` path (the only one a real device has, where
// no HID keyboard is reachable from the host) and `--clear`'s read-back.
//
// Split out of `IosHelperClient`. It is its own concern by the same test the rest of
// this directory uses — it is the only part that has to re-find a node ACROSS two
// captures, because emptying a field renumbers the tree, and that machinery
// (`refind`, `editableText`, the delete budget) serves nothing else.
extension IosHelperClient {
    /// `--type-delay <ms>`, as the CLI passes it through.
    func typeDelayMs(_ params: [String: Any]) -> Int? {
        if let value = params["typeDelayMs"] as? Int { return value }
        if let text = params["typeDelayMs"] as? String { return Int(text) }
        return nil
    }

    /// In-process typing via the agent's `/type` endpoint — the real-device path,
    /// where no HID keyboard is reachable from the host.
    ///
    /// The selector is resolved HERE, to a `ref`, through the shared
    /// `SelectorResolution`: that is what gives the device path the same `--label`
    /// / region / semantic-first precedence as everything else, instead of the
    /// agent growing a second, weaker resolver. With no selector the agent types
    /// into whatever holds focus, exactly as the HID path does.
    func typeInProcess(_ pkg: String, _ params: [String: Any], text: String) async throws -> [String: Any] {
        var selector: ReticleProtocol.Selector? = nil
        var focusedVia: String? = nil
        var resolvedAgainst: Snapshot? = nil
        let requested = selectorFromParams(params)
        if requested.describe() != "<empty>" {
            // A raw --point is passed straight through: the agent focuses a
            // canvas-toolkit field by touching it, which needs a coordinate and
            // not a node. Only a selector that WAS meant to name a node is
            // resolved to a ref here.
            if let css = requested.cssSelector, !css.isEmpty {
                // Passed through verbatim, exactly as `activate --css` does: the
                // agent resolves a DOM chain against the live page, and a ref
                // resolved here would be a handle into a tree the page may have
                // re-rendered out from under.
                selector = ReticleProtocol.Selector(cssSelector: css)
                focusedVia = "css"
            } else if params["point"] != nil, requested.point != nil, requested.ref == nil, requested.testId == nil {
                selector = requested
                focusedVia = "point"
            } else {
                let snapshot = try await fetchSnapshot(pkg)
                resolvedAgainst = snapshot
                let resolved = try resolveTarget(params, snapshot: snapshot)
                guard let ref = resolved.ref else {
                    throw HelperError("selector \(requested.describe()) resolved to a coordinate with no node, "
                        + "and in-process typing needs a node to focus")
                }
                // Route by what the target IS, not by which flag named it. A DOM
                // node has no UIKit responder to type into whatever selector
                // found it, so a `--ref`/`--test-id` that lands on one must take
                // the same page-level path `--css` does. It used to be decided by
                // the selector's kind, so the natural loop — `ui compact`, copy a
                // ref, `act type --ref` — answered `unsupported_text_target` for a
                // field that `--css` typed into fine. The snapshot is already in
                // hand here, so this costs nothing.
                if let chain = webChain(forRef: ref, in: snapshot) {
                    selector = ReticleProtocol.Selector(cssSelector: chain)
                    focusedVia = "ref->css"
                } else {
                    // The POINT rides along with the ref. A ref is a handle into
                    // the snapshot it came from, and the agent captures its own
                    // before resolving, so the rect resolved HERE is the sturdier
                    // half — and touching it is how a field takes focus anyway.
                    selector = ReticleProtocol.Selector(ref: ref, point: resolved.point)
                    focusedVia = "selector"
                }
            }
        }
        let request = TypeTextRequest(
            selector: selector, text: text,
            clear: isTruthy(params["clear"]), submit: isTruthy(params["submit"]),
            perCharDelayMs: typeDelayMs(params)
        )
        let body = try ReticleJSON.encodeWire(request)
        let (data, _) = try await IosAgentHTTP(bundleId: pkg).post(Endpoints.typeText, body: body)
        let r = try ReticleJSON.decode(TypeTextResult.self, from: data)
        guard r.typed else {
            throw HelperError("in-process type failed: \(r.message ?? "unknown") (ref=\(r.ref ?? "?"))")
        }
        var out: [String: Any] = ["gesture": "type", "via": "agent insertText", "text": text]
        if let inactive = inactiveWarning(resolvedAgainst) { out["warning"] = inactive }
        if let ref = r.ref { out["ref"] = ref }
        if let typeName = r.typeName { out["typeName"] = typeName }
        if let focusedVia { out["focusedVia"] = focusedVia }
        // The read-back IS the evidence the text landed — the device path has no
        // second channel (no HID echo, no screenshot of the keyboard) to fall back on.
        if let before = r.before { out["before"] = before }
        if let after = r.after { out["after"] = after }
        if r.secure == true { out["secure"] = true }
        if let cleared = r.cleared {
            out["cleared"] = cleared.emptied
                ? (cleared.deletes == 0 ? "already-empty" : "emptied(\(cleared.deletes)ch)")
                : "failed"
            out["clearDetail"] = ["emptied": cleared.emptied, "deletes": cleared.deletes,
                                  "before": cleared.before ?? "", "after": cleared.after ?? ""]
        }
        if let submitted = r.submitted { out["submit"] = ["via": submitted] }
        if let visible = (try? await IosAgentHTTP(bundleId: pkg).getJSONObject(Endpoints.keyboard))?["visible"] as? Bool {
            out["keyboardVisible"] = visible
        }
        return out
    }

    /// What `--clear` did on the iOS side, and whether the field is provably empty.
    struct ClearOutcome {
        var emptied: Bool
        var before: String?
        var after: String?
        var deletes: Int
        var unavailable: String?

        func describe() -> String {
            if let unavailable { return "the field could not be read back: \(unavailable)" }
            guard let after else { return "the field could not be read back" }
            // Quote what was actually read, before and after. A bare count sent the
            // reader looking for the wrong thing: measured on the login field, "it
            // still holds 14 char(s)" for a field holding six characters and a
            // separate eight-character placeholder node — the count alone could not
            // say which text had been read.
            let from = before.map { " (was \"\($0)\")" } ?? ""
            return "it still holds \(after.count) char(s)\(from): \"\(after)\""
        }

        /// One field, one token — see the Kotlin twin.
        var summary: String {
            if emptied && deletes == 0 { return "already-empty" }
            if emptied { return "emptied(\(deletes)ch)" }
            if let unavailable { return "failed:\(unavailable)" }
            return "failed:\(after?.count ?? 0)ch-left"
        }

        var wire: [String: Any] {
            var out: [String: Any] = ["emptied": emptied, "deletes": deletes]
            if let before { out["before"] = before }
            if let after { out["after"] = after }
            if let unavailable { out["unavailable"] = unavailable }
            return out
        }
    }

    /// The focused text field's current value, from the tree.
    private static func editableText(_ node: Node) -> String? {
        if case .text(let value)? = node.custom["editableText"] { return value }
        return node.text
    }

    /// The field the caller is typing into: the focused one, or the resolved target.
    private func focusedField(_ snapshot: Snapshot, params: [String: Any]) -> Node? {
        if let focused = snapshot.nodes.values.first(where: { $0.isFocused == true && $0.role == "textField" }) {
            return focused
        }
        guard let resolved = try? resolveTarget(params, snapshot: snapshot), let ref = resolved.ref else {
            return nil
        }
        return snapshot.nodes[ref]
    }

    /// Re-find a field in a LATER capture, by identity rather than by ref.
    ///
    /// Refs are traversal indices: emptying a field brings the keyboard's undo bar
    /// and its accessory views into the hierarchy, and the tree renumbers. Measured
    /// on the login screen — the capture grew from 71 nodes to 100, `r14` stopped
    /// being the text field, and `--clear` compared the field's old value against a
    /// STATUS LABEL ("was \"0123456\": \"Enter the code\""), concluded the field
    /// still held 14 characters and refused a clear that had in fact worked.
    ///
    /// The Android helper has always done this (`TypeReadback.refind`) for the same
    /// reason. Identity first (accessibility id), then a focused text field, then the
    /// frame's origin — position last, since a relayout moves rects too.
    static func refind(_ field: Node, in snapshot: Snapshot) -> Node? {
        if let id = field.testId, !id.isEmpty {
            let matches = snapshot.nodes.values.filter { $0.testId == id }
            if matches.count == 1 { return matches[0] }
        }
        if let focused = snapshot.nodes.values.first(where: {
            $0.isFocused == true && $0.role == "textField"
        }) {
            return focused
        }
        if let frame = field.frame {
            if let sameSpot = snapshot.nodes.values.first(where: {
                $0.role == "textField" && $0.frame?.x == frame.x && $0.frame?.y == frame.y
            }) {
                return sameSpot
            }
        }
        // Last resort, and only when the ref still names the same kind of thing.
        return snapshot.nodes[field.ref].flatMap { $0.typeName == field.typeName ? $0 : nil }
    }

    /// Empty the focused field with one Delete per character it actually holds,
    /// then read it back. Deleting what is there rather than a fixed count is the
    /// difference between clearing the field and eating the line above it; the
    /// read-back is what stops `--clear` claiming work it did not do.
    func clearFocusedField(_ pkg: String, udid: String, params: [String: Any]) async throws -> ClearOutcome {
        let snapshot = try await fetchSnapshot(pkg)
        guard let field = focusedField(snapshot, params: params) else {
            return ClearOutcome(emptied: false, before: nil, after: nil, deletes: 0,
                                unavailable: "no-text-field-node")
        }
        guard let before = Self.editableText(field) else {
            return ClearOutcome(emptied: false, before: nil, after: nil, deletes: 0,
                                unavailable: "field-exposes-no-text")
        }
        if before.isEmpty {
            return ClearOutcome(emptied: true, before: before, after: before, deletes: 0, unavailable: nil)
        }
        if before.count > Self.maxClearDeletes {
            return ClearOutcome(
                emptied: false, before: before, after: before, deletes: 0,
                unavailable: "field-too-long (\(before.count) chars, limit \(Self.maxClearDeletes))"
            )
        }
        try IosInputBackend(udid: udid).delete(times: before.count)
        try? await Task.sleep(for: .seconds(0.25))
        let after = (try? await fetchSnapshot(pkg))
            .flatMap { Self.refind(field, in: $0) }
            .flatMap { Self.editableText($0) }
        return ClearOutcome(
            emptied: after?.isEmpty == true, before: before, after: after,
            deletes: before.count, unavailable: after == nil ? "node-gone" : nil
        )
    }

    /// A field longer than this is not hammered with hundreds of key events — it is
    /// reported as not cleared and the caller decides. Matches the Android limit.
    static let maxClearDeletes = 64
}
