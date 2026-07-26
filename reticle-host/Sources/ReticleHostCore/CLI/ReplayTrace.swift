import Foundation

/// One action step recovered from a `trace.json` evidence package, reduced to
/// what the replay renderer needs: the screenshots, the caption ingredients
/// (gesture + selector + result), and the gesture geometry for the overlay
/// marker. Parsing is manifest-shaped (`JSONSerialization`), like
/// `ActionTraceIngest` — both platforms write the same manifest, so one reader
/// covers Android and iOS traces.
struct ReplayStep {
    let directory: URL
    let actionId: String
    let recordedAtMillis: Int64
    let gesture: String
    let selectorDescription: String?
    /// Resolved tap point (`target.point`), in screenshot pixel space.
    let tapPoint: CGPoint?
    /// Swipe/drag endpoints (`result.from` / `result.to`), in screenshot pixel space.
    let strokeFrom: CGPoint?
    let strokeTo: CGPoint?
    /// Gesture-specific detail for the caption (e.g. `12 chars` for type).
    let resultDetail: String?
    let changeCount: Int?
    let beforeScreenshot: URL?
    let afterScreenshot: URL?
    /// Width of the coordinate space the gesture geometry lives in, read from
    /// the trace's own snapshot (`screen.size.width`). On Android this equals
    /// the screenshot pixel width; on iOS it is points while the screenshot is
    /// device pixels — the renderer scales markers through this, never through
    /// the image width, so both platforms land correctly.
    let coordinateSpaceWidth: CGFloat?

    var hasScreenshot: Bool { beforeScreenshot != nil || afterScreenshot != nil }

    /// Caption text for this step, e.g. `3/7 tap testId=checkout.payButton`.
    func caption(index: Int, count: Int) -> String {
        var parts = ["\(index)/\(count)", gesture]
        if let selectorDescription {
            parts.append(selectorDescription)
        } else if let from = strokeFrom, let to = strokeTo {
            parts.append("\(Self.pointString(from)) → \(Self.pointString(to))")
        } else if let tapPoint {
            parts.append(Self.pointString(tapPoint))
        }
        if let resultDetail { parts.append(resultDetail) }
        return parts.joined(separator: " ")
    }

    private static func pointString(_ p: CGPoint) -> String {
        "(\(Int(p.x)),\(Int(p.y)))"
    }
}

enum ReplayTraceDiscovery {
    /// Loads the replay steps under `root`, which is either a single trace
    /// directory (contains `trace.json`) or a trace-output root holding one
    /// subdirectory per action (the shape `act --trace-output` produces).
    /// Steps come back in recording order.
    static func steps(at root: URL) throws -> [ReplayStep] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw HelperError("trace directory not found: \(root.path)")
        }

        var traceDirs: [URL] = []
        if fm.fileExists(atPath: root.appendingPathComponent("trace.json").path) {
            traceDirs = [root]
        } else {
            let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            traceDirs = children.filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && fm.fileExists(atPath: $0.appendingPathComponent("trace.json").path)
            }
        }
        guard !traceDirs.isEmpty else {
            throw HelperError("no trace.json found under \(root.path) — record one with `act … --trace-output <dir>`")
        }

        let steps = try traceDirs.map { try step(at: $0) }
        return steps.sorted {
            ($0.recordedAtMillis, $0.directory.lastPathComponent)
                < ($1.recordedAtMillis, $1.directory.lastPathComponent)
        }
    }

    static func step(at directory: URL) throws -> ReplayStep {
        let manifestURL = directory.appendingPathComponent("trace.json")
        let any = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))
        guard let manifest = any as? [String: Any] else {
            throw HelperError("trace file must contain a JSON object: \(manifestURL.path)")
        }

        let result = manifest["result"] as? [String: Any] ?? [:]
        let target = manifest["target"] as? [String: Any]
        let gesture = manifest["gesture"] as? String ?? "action"

        return ReplayStep(
            directory: directory,
            actionId: manifest["actionId"] as? String ?? directory.lastPathComponent,
            recordedAtMillis: (manifest["recordedAtMillis"] as? NSNumber)?.int64Value ?? 0,
            gesture: gesture,
            selectorDescription: selectorDescription(manifest["selector"] as? [String: Any]),
            tapPoint: point(from: target?["point"]),
            strokeFrom: point(fromPair: result["from"]),
            strokeTo: point(fromPair: result["to"]),
            resultDetail: resultDetail(gesture: gesture, result: result),
            changeCount: (manifest["diff"] as? [Any])?.count,
            beforeScreenshot: artifactURL(manifest, key: "beforeScreenshot", directory: directory),
            afterScreenshot: artifactURL(manifest, key: "afterScreenshot", directory: directory),
            coordinateSpaceWidth: coordinateSpaceWidth(manifest, directory: directory)
        )
    }

    /// Reads `screen.size.width` from the trace's before (or after) snapshot.
    private static func coordinateSpaceWidth(_ manifest: [String: Any], directory: URL) -> CGFloat? {
        for key in ["beforeSnapshot", "afterSnapshot"] {
            guard let url = artifactURL(manifest, key: key, directory: directory),
                  let any = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)),
                  let snapshot = any as? [String: Any],
                  let screen = snapshot["screen"] as? [String: Any],
                  let size = screen["size"] as? [String: Any],
                  let width = double(size["width"]), width > 0 else { continue }
            return CGFloat(width)
        }
        return nil
    }

    private static func selectorDescription(_ selector: [String: Any]?) -> String? {
        guard let selector else { return nil }
        if let v = selector["testId"] as? String { return "testId=\(v)" }
        if let v = selector["resourceId"] as? String { return "id=\(v)" }
        if let v = selector["cssSelector"] as? String { return "css=\(v)" }
        if let v = selector["region"] as? String { return "region=\(v)" }
        if let v = selector["ref"] as? String { return "ref=\(v)" }
        if let p = point(from: selector["point"]) { return "point=(\(Int(p.x)),\(Int(p.y)))" }
        return nil
    }

    private static func resultDetail(gesture: String, result: [String: Any]) -> String? {
        guard gesture == "type" else { return nil }
        // The trace records character count, not the text — keep it that way.
        if let chars = result["chars"] { return "\(scalar(chars)) chars" }
        return nil
    }

    /// Reads a `{x, y}` object (numbers, or the strings a Kotlin scalar map produces).
    private static func point(from any: Any?) -> CGPoint? {
        guard let o = any as? [String: Any],
              let x = double(o["x"]), let y = double(o["y"]) else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Reads an `"x,y"` pair — the shape `result.from` / `result.to` use.
    private static func point(fromPair any: Any?) -> CGPoint? {
        guard let s = any as? String else { return nil }
        let parts = s.split(separator: ",")
        guard parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func double(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func scalar(_ any: Any) -> String {
        if let n = any as? NSNumber { return n.stringValue }
        return String(describing: any)
    }

    private static func artifactURL(_ manifest: [String: Any], key: String, directory: URL) -> URL? {
        guard let artifacts = manifest["artifacts"] as? [String: Any],
              let name = artifacts[key] as? String,
              // Same guard as ActionTraceIngest: artifact names are plain
              // filenames inside the trace directory, never paths.
              !name.isEmpty, !name.contains("/"), name != "..", name != "." else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
