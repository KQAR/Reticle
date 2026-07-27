import Foundation
import ReticleHostShared
import ReticleProtocol

/// Writes the per-action evidence package for iOS actions — the Swift analogue
/// of the Kotlin helper's `HelperActionTrace`. It produces the same on-disk
/// shape (before/after snapshots + screenshots + a `trace.json` manifest) so
/// `reticle serve` ingestion and the web panel consume an iOS trace exactly like
/// an Android one. The only added manifest field is `platform`, which lets the
/// daemon label the event `ios:<pkg>` instead of assuming Android.
struct IosActionTrace {
    struct Capture {
        /// Raw snapshot bytes as the agent emitted them — written verbatim so the
        /// artifact is byte-faithful and never drifts through a re-encode.
        let snapshotJSON: Data
        /// Decoded snapshot, used only to compute the diff.
        let snapshot: Snapshot
        let screenshotPNG: Data?
    }

    let root: URL
    let packageName: String
    let http: IosAgentHTTP
    /// Gesture-shaping inputs, captured from the request at construction.
    let recordedParams: [String: String]

    /// Capture a snapshot (+ best-effort screenshot) from the running agent. A
    /// missing screenshot is not fatal — the trace still records the snapshots.
    func capture() -> Capture? {
        guard let (snapData, _) = try? http.get(Endpoints.snapshot),
              let snapshot = try? ReticleJSON.decode(Snapshot.self, from: snapData) else { return nil }
        let png = (try? http.get(Endpoints.screenshot))?.data
        return Capture(snapshotJSON: snapData, snapshot: snapshot, screenshotPNG: png)
    }

    /// Write the before/after artifacts and `trace.json`, returning the compact
    /// `trace` result dict the host prints and publishes to the daemon.
    func write(
        gesture: String,
        selector: ReticleProtocol.Selector?,
        targetPoint: Point?,
        targetSource: String?,
        targetRef: String?,
        result: [String: String],
        before: Capture,
        settleMs: Int
    ) throws -> [String: Any] {
        if settleMs > 0 { Thread.sleep(forTimeInterval: Double(settleMs) / 1000.0) }
        guard let after = capture() else {
            throw HelperError("action trace: could not capture the after-state snapshot")
        }
        let recordedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let actionId = "\(recordedAt)-\(gesture)"
        let dir = try uniqueTraceDir(actionId)

        let beforeSnapshot = "before.snapshot.json"
        let afterSnapshot = "after.snapshot.json"
        try before.snapshotJSON.write(to: dir.appendingPathComponent(beforeSnapshot))
        try after.snapshotJSON.write(to: dir.appendingPathComponent(afterSnapshot))
        let beforeScreenshot = before.screenshotPNG != nil ? "before.screenshot.png" : nil
        let afterScreenshot = after.screenshotPNG != nil ? "after.screenshot.png" : nil
        if let png = before.screenshotPNG { try png.write(to: dir.appendingPathComponent(beforeScreenshot!)) }
        if let png = after.screenshotPNG { try png.write(to: dir.appendingPathComponent(afterScreenshot!)) }

        let diff = ActionTraceDiff.compare(before: before.snapshot, after: after.snapshot)

        var artifacts: [String: Any] = ["beforeSnapshot": beforeSnapshot, "afterSnapshot": afterSnapshot]
        if let beforeScreenshot { artifacts["beforeScreenshot"] = beforeScreenshot }
        if let afterScreenshot { artifacts["afterScreenshot"] = afterScreenshot }

        var manifest: [String: Any] = [
            "traceVersion": 1,
            "platform": before.snapshot.platform.isEmpty ? "ios" : before.snapshot.platform,
            "actionId": actionId,
            "packageName": packageName,
            "recordedAtMillis": recordedAt,
            "gesture": gesture,
            "result": result,
            "artifacts": artifacts,
            "diff": diff,
        ]
        if !recordedParams.isEmpty { manifest["params"] = recordedParams }
        if let selJSON = selectorJSON(selector) { manifest["selector"] = selJSON }
        if let tgtJSON = targetJSON(point: targetPoint, source: targetSource, ref: targetRef) {
            manifest["target"] = tgtJSON
        }

        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: dir.appendingPathComponent("trace.json"))

        var out: [String: Any] = [
            "actionId": actionId,
            "path": dir.path,
            "changeCount": diff.count,
            "beforeSnapshot": beforeSnapshot,
            "afterSnapshot": afterSnapshot,
            "manifest": "trace.json",
        ]
        if let beforeScreenshot { out["beforeScreenshot"] = beforeScreenshot }
        if let afterScreenshot { out["afterScreenshot"] = afterScreenshot }
        return out
    }

    private func uniqueTraceDir(_ actionId: String) throws -> URL {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: root.path, isDirectory: &isDir), !isDir.boolValue {
            throw HelperError("traceOutput is not a directory: \(root.path)")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var candidate = root.appendingPathComponent(actionId)
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(actionId)-\(suffix)")
            suffix += 1
        }
        try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate
    }

    private func selectorJSON(_ selector: ReticleProtocol.Selector?) -> [String: Any]? {
        guard let s = selector else { return nil }
        var o: [String: Any] = [:]
        if let v = s.testId { o["testId"] = v }
        if let v = s.resourceId { o["resourceId"] = v }
        if let v = s.cssSelector { o["cssSelector"] = v }
        if let v = s.ref { o["ref"] = v }
        if let p = s.point { o["point"] = ["x": p.x, "y": p.y] }
        if let v = s.region { o["region"] = v }
        return o.isEmpty ? nil : o
    }

    private func targetJSON(point: Point?, source: String?, ref: String?) -> [String: Any]? {
        var o: [String: Any] = [:]
        if let p = point { o["point"] = ["x": p.x, "y": p.y] }
        if let source { o["source"] = source }
        if let ref { o["ref"] = ref }
        return o.isEmpty ? nil : o
    }
}

/// Pure snapshot diffing for iOS action traces — a faithful port of
/// `dev.reticle.core.trace.ActionTraceDiff` so both platforms emit the same
/// compact before/after change list. Each change is `{ref?, field, before?,
/// after?, node?, note?}`; nil fields are omitted (a missing key decodes to
/// null). Both ports are pinned by
/// `reticle-protocol/fixtures/action-trace-diff.cases.json`.
enum ActionTraceDiff {
    /// Longest node text carried as identity before clipping.
    static let identityTextLimit = 60

    /// How much a field says about what an action DID, lowest rank listed first.
    ///
    /// Ordering is not cosmetic: the list is capped, so whatever sorts last is
    /// what gets dropped. Ranking by field means a cap spends its budget on
    /// appearances and text changes, and sheds pixel-level `frame` churn — the
    /// previous alphabetical-by-ref order could spend all 100 slots on the frames
    /// of a scrolling list and truncate away the one node that appeared.
    private static func fieldRank(_ field: String) -> Int {
        switch field {
        // A node appearing or disappearing is the strongest evidence an action landed.
        case "present": return 0
        // What the user would see change.
        case "text", "label", "enabled", "visible": return 1
        // Identity and affordance: rarer, and meaningful when they do move.
        case "testId", "resourceId", "role", "kind", "interactive", "regions": return 2
        // Geometry, structure, counts, and custom.* — the noisy tail. Animation
        // and scrolling produce these by the hundred without an action landing.
        default: return 3
        }
    }

    /// How addressable the changed node is, lowest listed first.
    ///
    /// The second half of ranking, and it is not a nicety. A screen transition
    /// makes hundreds of nodes appear at once, and by field rank alone they tie —
    /// so the cap filled with whatever the ref order happened to hit first, which
    /// on a SwiftUI or Compose screen is layout scaffolding. Six lines of
    /// `+ r104 [role=container]` describe nothing. A node carrying a testId is
    /// both the likelier subject of the action and the only one a reader can do
    /// anything with afterwards.
    private static func identityRank(_ node: Node?) -> Int {
        // A ref-less change (nodeCount) is not an unaddressable node — it is not
        // about a node at all. Ranking a whole-screen summary by "how addressable
        // is it" is a category error, and ranking it LAST let one line of genuine
        // context get truncated away in favour of a container's child list.
        guard let node else { return 0 }
        if node.testId != nil || node.resourceId != nil { return 0 }
        if node.contentDescription != nil || node.text != nil { return 1 }
        return 2
    }

    static func compare(before: Snapshot, after: Snapshot, maxChanges: Int = 100) -> [[String: Any]] {
        var found: [(ref: String?, field: String, identityRank: Int, change: [String: Any])] = []
        func add(_ ref: String?, _ field: String, _ old: String?, _ new: String?) {
            if old == new { return }
            var change: [String: Any] = ["field": field]
            if let ref { change["ref"] = ref }
            if let old { change["before"] = old }
            if let new { change["after"] = new }
            let node = ref.flatMap { after.nodes[$0] ?? before.nodes[$0] }
            found.append((ref: ref, field: field, identityRank: identityRank(node), change: change))
        }

        add(nil, "nodeCount", String(before.nodes.count), String(after.nodes.count))
        let refs = Set(before.nodes.keys).union(after.nodes.keys).sorted()
        for ref in refs {
            switch (before.nodes[ref], after.nodes[ref]) {
            case (nil, .some): add(ref, "present", "false", "true")
            case (.some, nil): add(ref, "present", "true", "false")
            case let (.some(b), .some(a)): compareNode(ref, b, a, add)
            case (nil, nil): break
            }
        }

        // Rank first, then cap: by field, then by how addressable the node is,
        // then by traversal order. Swift's sort is not stable, so the original
        // index is part of the key — that keeps traversal order inside a rank and
        // the result identical to Kotlin's for the shared fixture.
        let ranked = found.enumerated()
            .sorted { lhs, rhs in
                let lf = fieldRank(lhs.element.field), rf = fieldRank(rhs.element.field)
                if lf != rf { return lf < rf }
                if lhs.element.identityRank != rhs.element.identityRank {
                    return lhs.element.identityRank < rhs.element.identityRank
                }
                return lhs.offset < rhs.offset
            }
            .map { $0.element }
        let kept = Array(ranked.prefix(maxChanges))
        let dropped = Array(ranked.dropFirst(maxChanges))

        // Name each ref once, on its first surviving change, so three fields moving
        // on one node cost one identity rather than three.
        var named = Set<String>()
        var out: [[String: Any]] = []
        out.reserveCapacity(kept.count + 1)
        for entry in kept {
            var change = entry.change
            if let ref = entry.ref, named.insert(ref).inserted,
               let node = identity(after.nodes[ref] ?? before.nodes[ref]) {
                change["node"] = node
            }
            out.append(change)
        }
        if !dropped.isEmpty {
            // Say what was dropped, not just how much. "truncated: 100" reads as
            // "you have the interesting part"; it never was a safe thing to assume.
            out.append([
                "field": "truncated",
                "before": String(found.count),
                "after": String(kept.count),
                "note": "dropped by field: " + droppedSummary(dropped),
            ])
        }
        return out
    }

    /// `frame 96, children 31, custom.badge 4` — the heaviest field names first.
    private static func droppedSummary(
        _ dropped: [(ref: String?, field: String, identityRank: Int, change: [String: Any])],
        maxNames: Int = 6
    ) -> String {
        var counts: [String: Int] = [:]
        for entry in dropped { counts[entry.field, default: 0] += 1 }
        let ordered = counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }
        let shown = ordered.prefix(maxNames).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let rest = ordered.dropFirst(maxNames)
        if rest.isEmpty { return shown }
        let total = rest.reduce(0) { $0 + $1.value }
        return "\(shown), and \(rest.count) more field(s) totalling \(total)"
    }

    private static func identity(_ node: Node?) -> [String: Any]? {
        guard let node else { return nil }
        let anonymous = node.testId == nil && node.resourceId == nil && node.contentDescription == nil
        let text = anonymous ? node.text.flatMap(clipIdentityText) : nil
        var o: [String: Any] = [:]
        if let v = node.testId { o["testId"] = v }
        if let v = node.resourceId { o["resourceId"] = v }
        if let v = node.contentDescription { o["label"] = v }
        if let v = node.role { o["role"] = v }
        if let v = text { o["text"] = v }
        return o.isEmpty ? nil : o
    }

    /// Collapse to one line and clip, so identity never breaks a line-oriented
    /// reader and never costs more than a glance.
    ///
    /// Both the whitespace set and the clip unit are spelled out rather than
    /// inherited from the platform: Swift's `isWhitespace` and Kotlin's `\s` cover
    /// different characters, and `prefix` counts grapheme clusters while Kotlin's
    /// `take` counts UTF-16 units. Left to defaults the two ports would agree on
    /// ASCII and quietly disagree on CJK, emoji, and NBSP. Clipping is by Unicode
    /// scalar, which is exactly one code point on the Kotlin side.
    private static func clipIdentityText(_ text: String) -> String? {
        let collapsed = collapseWhitespace(text)
        if collapsed.isEmpty { return nil }
        let scalars = Array(collapsed.unicodeScalars)
        if scalars.count <= identityTextLimit { return collapsed }
        return String(String.UnicodeScalarView(scalars.prefix(identityTextLimit))) + "…"
    }

    /// Java's `\s`, written out so this matches the Kotlin port exactly.
    private static func isTraceWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n"
            || scalar == "\u{000B}" || scalar == "\u{000C}" || scalar == "\r"
    }

    private static func collapseWhitespace(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingGap = false
        for scalar in text.unicodeScalars {
            if isTraceWhitespace(scalar) {
                if !out.isEmpty { pendingGap = true }
                continue
            }
            if pendingGap {
                out.append(" ")
                pendingGap = false
            }
            out.append(scalar)
        }
        return String(out)
    }

    private static func compareNode(
        _ ref: String, _ before: Node, _ after: Node,
        _ add: (String?, String, String?, String?) -> Void
    ) {
        add(ref, "kind", before.kind.rawValue, after.kind.rawValue)
        add(ref, "role", before.role, after.role)
        add(ref, "text", before.text, after.text)
        add(ref, "label", before.contentDescription, after.contentDescription)
        add(ref, "testId", before.testId, after.testId)
        add(ref, "resourceId", before.resourceId, after.resourceId)
        add(ref, "frame", before.frame.map(rectString), after.frame.map(rectString))
        add(ref, "visible", String(before.isVisible), String(after.isVisible))
        add(ref, "enabled", String(before.isEnabled), String(after.isEnabled))
        add(ref, "interactive", String(before.isInteractive), String(after.isInteractive))
        add(ref, "children", before.children.joined(separator: ","), after.children.joined(separator: ","))
        add(ref, "regions", String(before.regions.count), String(after.regions.count))
        let customKeys = Set(before.custom.keys).union(after.custom.keys).sorted()
        for key in customKeys {
            add(ref, "custom.\(key)", before.custom[key]?.displayString(), after.custom[key]?.displayString())
        }
    }

    private static func rectString(_ r: Rect) -> String {
        r.intDescription
    }
}
