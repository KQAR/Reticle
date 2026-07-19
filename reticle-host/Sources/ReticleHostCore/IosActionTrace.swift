import Foundation
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
/// after?}`; nil fields are omitted (a missing key decodes to null).
enum ActionTraceDiff {
    static func compare(before: Snapshot, after: Snapshot, maxChanges: Int = 100) -> [[String: Any]] {
        var out: [[String: Any]] = []
        func add(_ ref: String?, _ field: String, _ old: String?, _ new: String?) {
            if old == new || out.count >= maxChanges { return }
            var change: [String: Any] = ["field": field]
            if let ref { change["ref"] = ref }
            if let old { change["before"] = old }
            if let new { change["after"] = new }
            out.append(change)
        }

        add(nil, "nodeCount", String(before.nodes.count), String(after.nodes.count))
        let refs = Set(before.nodes.keys).union(after.nodes.keys).sorted()
        for ref in refs {
            if out.count >= maxChanges { break }
            switch (before.nodes[ref], after.nodes[ref]) {
            case (nil, .some): add(ref, "present", "false", "true")
            case (.some, nil): add(ref, "present", "true", "false")
            case let (.some(b), .some(a)): compareNode(ref, b, a, add)
            case (nil, nil): break
            }
        }
        if out.count >= maxChanges {
            out.append(["field": "truncated", "after": String(maxChanges)])
        }
        return out
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
        "\(Int(r.x)),\(Int(r.y)) \(Int(r.width))x\(Int(r.height))"
    }
}
