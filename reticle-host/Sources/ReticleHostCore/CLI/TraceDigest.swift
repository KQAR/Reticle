import Foundation
import ReticleHostShared

/// `reticle trace log` — what a run of actions actually did, in a form small
/// enough to read.
///
/// The evidence a trace holds is already good: two snapshots, two screenshots, a
/// ranked diff. What it lacked was a way to consume it. Reconstructing a
/// six-action run meant opening six manifests and, whenever a change named a
/// bare `ref`, the 100KB+ snapshot beside it — hundreds of kilobytes to answer
/// "did the tap land". This renders the same evidence as a handful of lines per
/// action, which is what a reader on a budget can actually use.
///
/// Deliberately NOT a replay script and NOT a verdict. Every line is something
/// that was recorded; nothing here decides whether the run passed. `replay`
/// re-sends network flows and renders GIFs — different verb, different command.
enum TraceDigest {

    /// One recorded action, flattened out of a `trace.json` manifest.
    struct Entry {
        let directory: URL
        let recordedAtMillis: Int64
        let platform: String?
        let packageName: String?
        let gesture: String
        let selectorDescription: String?
        /// Gesture inputs as the caller gave them (`text`, `submit`, …).
        let params: [(key: String, value: String)]
        /// Where the gesture landed, e.g. `540,1033 semantic:testId`.
        let targetDescription: String?
        let changes: [Change]
        /// Present when the manifest's own diff hit its cap.
        let manifestTruncation: String?
        let snapshotCount: Int
        let screenshotCount: Int

        /// Changes excluding the `truncated` bookkeeping marker.
        var realChanges: [Change] { changes.filter { $0.field != "truncated" } }
    }

    struct Change {
        let ref: String?
        let field: String
        let before: String?
        let after: String?
        let identity: String?
        let note: String?

        /// `+` appeared, `-` disappeared, `~` changed in place.
        var mark: String {
            guard field == "present" else { return "~" }
            return after == "true" ? "+" : "-"
        }
    }

    // MARK: - reading

    static func entries(at root: URL) throws -> [Entry] {
        let dirs = try ReplayTraceDiscovery.directories(at: root)
        return dirs.compactMap(entry(at:)).sorted {
            ($0.recordedAtMillis, $0.directory.lastPathComponent)
                < ($1.recordedAtMillis, $1.directory.lastPathComponent)
        }
    }

    static func entry(at directory: URL) -> Entry? {
        let manifestURL = directory.appendingPathComponent("trace.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        let rawDiff = manifest["diff"] as? [[String: Any]] ?? []
        var changes: [Change] = []
        var manifestTruncation: String?
        for raw in rawDiff {
            let field = raw["field"] as? String ?? "?"
            if field == "truncated" {
                // The manifest already shed changes at capture time. Say so —
                // otherwise a short digest looks like a quiet screen.
                let total = raw["before"] as? String ?? "?"
                let kept = raw["after"] as? String ?? "?"
                let note = raw["note"] as? String
                manifestTruncation = "manifest kept \(kept) of \(total) changes"
                    + (note.map { " (\($0))" } ?? "")
                continue
            }
            changes.append(Change(
                ref: raw["ref"] as? String,
                field: field,
                before: raw["before"] as? String,
                after: raw["after"] as? String,
                identity: identityDescription(raw["node"] as? [String: Any]),
                note: raw["note"] as? String
            ))
        }

        let artifacts = manifest["artifacts"] as? [String: Any] ?? [:]
        let params = manifest["params"] as? [String: Any] ?? [:]

        return Entry(
            directory: directory,
            recordedAtMillis: (manifest["recordedAtMillis"] as? NSNumber)?.int64Value ?? 0,
            platform: manifest["platform"] as? String,
            packageName: manifest["packageName"] as? String,
            gesture: manifest["gesture"] as? String ?? "action",
            selectorDescription: selectorDescription(manifest["selector"] as? [String: Any]),
            params: orderedParams(params),
            targetDescription: targetDescription(manifest["target"] as? [String: Any]),
            changes: changes,
            manifestTruncation: manifestTruncation,
            snapshotCount: ["beforeSnapshot", "afterSnapshot"].filter { artifacts[$0] != nil }.count,
            screenshotCount: ["beforeScreenshot", "afterScreenshot"].filter { artifacts[$0] != nil }.count
        )
    }

    /// Params in the recorded order, not the dictionary's, so two digests of the
    /// same gesture read the same way.
    private static func orderedParams(_ params: [String: Any]) -> [(key: String, value: String)] {
        ActionTraceParamNames.recorded.compactMap { key in
            guard let value = params[key] else { return nil }
            return (key: key, value: value as? String ?? "\(value)")
        }
    }

    private static func identityDescription(_ node: [String: Any]?) -> String? {
        guard let node else { return nil }
        var parts: [String] = []
        if let v = node["testId"] as? String { parts.append("testId=\(v)") }
        if let v = node["resourceId"] as? String { parts.append("id=\(v)") }
        if let v = node["label"] as? String { parts.append("label=\(quoted(v))") }
        if let v = node["role"] as? String { parts.append("role=\(v)") }
        if let v = node["text"] as? String { parts.append("text=\(quoted(v))") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func selectorDescription(_ selector: [String: Any]?) -> String? {
        guard let selector else { return nil }
        if let v = selector["testId"] as? String { return "testId=\(v)" }
        if let v = selector["resourceId"] as? String { return "id=\(v)" }
        if let v = selector["cssSelector"] as? String { return "css=\(v)" }
        if let v = selector["region"] as? String { return "region=\(quoted(v))" }
        if let v = selector["ref"] as? String { return "ref=\(v)" }
        if let p = selector["point"] as? [String: Any],
           let x = number(p["x"]), let y = number(p["y"]) { return "point=\(x),\(y)" }
        return nil
    }

    private static func targetDescription(_ target: [String: Any]?) -> String? {
        guard let target else { return nil }
        var parts: [String] = []
        if let p = target["point"] as? [String: Any],
           let x = number(p["x"]), let y = number(p["y"]) { parts.append("\(x),\(y)") }
        if let source = target["source"] as? String { parts.append(source) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func number(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return Int(n.doubleValue.rounded()) }
        if let s = any as? String, let d = Double(s) { return Int(d.rounded()) }
        return nil
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value)\""
    }

    // MARK: - rendering

    /// Renders the digest. `maxChanges` bounds the changes shown per action; the
    /// rest are counted by field rather than dropped in silence — the diff is
    /// already ranked, so the ones shown are the ones that matter most.
    static func render(_ entries: [Entry], root: URL, maxChanges: Int) -> String {
        guard !entries.isEmpty else {
            return "no actions recorded under \(root.path)"
        }
        var lines: [String] = []
        lines.append("recording \(root.path)")

        let platforms = Set(entries.compactMap { $0.platform }).sorted()
        let packages = Set(entries.compactMap { $0.packageName }).sorted()
        var header: [String] = []
        if !platforms.isEmpty { header.append(platforms.joined(separator: "+")) }
        if !packages.isEmpty { header.append(packages.joined(separator: " ")) }
        header.append("\(entries.count) action\(entries.count == 1 ? "" : "s")")
        if let first = entries.first, let last = entries.last, first.recordedAtMillis > 0 {
            header.append("\(clock(first.recordedAtMillis)) → \(clock(last.recordedAtMillis))")
        }
        lines.append(header.joined(separator: " · "))
        lines.append("")

        for (index, entry) in entries.enumerated() {
            lines.append(contentsOf: renderEntry(entry, index: index + 1, maxChanges: maxChanges))
        }
        return lines.joined(separator: "\n")
    }

    private static func renderEntry(_ entry: Entry, index: Int, maxChanges: Int) -> [String] {
        var head = ["\(index)", clock(entry.recordedAtMillis), entry.gesture]
        if let selector = entry.selectorDescription { head.append(selector) }
        if let target = entry.targetDescription { head.append("→\(target)") }
        for param in entry.params { head.append(renderParam(param)) }
        var lines = [head.joined(separator: "  ")]

        let shown = entry.realChanges.prefix(maxChanges)
        if entry.realChanges.isEmpty {
            // The most under-reported result there is. An action that dispatched
            // cleanly and changed nothing observable looks identical to a
            // successful one unless the digest says this out loud.
            lines.append("    (no observable change between before and after)")
        }
        for change in shown {
            lines.append("    " + renderChange(change))
        }
        let hidden = entry.realChanges.count - shown.count
        if hidden > 0 {
            lines.append("    …\(hidden) more (\(fieldCounts(entry.realChanges.dropFirst(shown.count))))")
        }
        if let truncation = entry.manifestTruncation {
            lines.append("    ! \(truncation)")
        }

        var artifacts = ["\(entry.directory.lastPathComponent)/"]
        if entry.snapshotCount > 0 { artifacts.append("\(entry.snapshotCount) snapshot\(entry.snapshotCount == 1 ? "" : "s")") }
        if entry.screenshotCount > 0 { artifacts.append("\(entry.screenshotCount) screenshot\(entry.screenshotCount == 1 ? "" : "s")") }
        lines.append("    evidence " + artifacts.joined(separator: ", "))
        lines.append("")
        return lines
    }

    private static func renderParam(_ param: (key: String, value: String)) -> String {
        // `submit` / `settle` / `gone` / `idle` read as flags when true.
        if param.value == "true" { return param.key }
        if param.value == "false" { return "\(param.key)=false" }
        return "\(param.key)=\(quoted(param.value))"
    }

    private static func renderChange(_ change: Change) -> String {
        var parts = [change.mark]
        // A screen-level change (nodeCount) has no ref. Printing a placeholder
        // there would collide with `-`, which already means "disappeared".
        if let ref = change.ref { parts.append(ref) }
        // For an appearance/disappearance the mark already carries the fact.
        if change.field != "present" {
            parts.append(change.field)
            parts.append("\(display(change.before)) → \(display(change.after))")
        }
        if let identity = change.identity { parts.append("[\(identity)]") }
        if let note = change.note { parts.append("(\(note))") }
        return parts.joined(separator: " ")
    }

    private static func display(_ value: String?) -> String {
        guard let value else { return "-" }
        if value.isEmpty { return "\"\"" }
        // Booleans and numbers read better bare; anything else is text.
        if value == "true" || value == "false" || Double(value) != nil { return value }
        return quoted(value)
    }

    private static func fieldCounts<C: Collection>(_ changes: C) -> String where C.Element == Change {
        var counts: [String: Int] = [:]
        for change in changes { counts[change.field, default: 0] += 1 }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: ", ")
    }

    /// `18:44:55` in local time. Traces are read on the machine that recorded
    /// them, so local time is what a reader can line up against their own logs.
    private static func clock(_ millis: Int64) -> String {
        guard millis > 0 else { return "--:--:--" }
        var seconds = time_t(millis / 1000)
        var parts = tm()
        localtime_r(&seconds, &parts)
        return String(format: "%02d:%02d:%02d", parts.tm_hour, parts.tm_min, parts.tm_sec)
    }

    // MARK: - JSON

    static func jsonObject(_ entries: [Entry], root: URL) -> [String: Any] {
        [
            "root": root.path,
            "count": entries.count,
            "actions": entries.map { entry in
                var o: [String: Any] = [
                    "directory": entry.directory.path,
                    "recordedAtMillis": entry.recordedAtMillis,
                    "gesture": entry.gesture,
                    "changeCount": entry.realChanges.count,
                    "changes": entry.realChanges.map { change in
                        var c: [String: Any] = ["field": change.field, "mark": change.mark]
                        if let v = change.ref { c["ref"] = v }
                        if let v = change.before { c["before"] = v }
                        if let v = change.after { c["after"] = v }
                        if let v = change.identity { c["node"] = v }
                        return c
                    },
                ]
                if let v = entry.platform { o["platform"] = v }
                if let v = entry.packageName { o["packageName"] = v }
                if let v = entry.selectorDescription { o["selector"] = v }
                if let v = entry.targetDescription { o["target"] = v }
                if let v = entry.manifestTruncation { o["manifestTruncation"] = v }
                if !entry.params.isEmpty {
                    o["params"] = Dictionary(uniqueKeysWithValues: entry.params.map { ($0.key, $0.value) })
                }
                return o
            },
        ]
    }
}
