import Foundation

/// Converts existing `trace.json` action evidence packages into daemon events.
public struct ActionTraceIngest {
    private let decoder = JSONDecoder()

    /// Builds an event post body from either a manifest object or `{ "path": ... }`.
    public func event(from body: Data, relativeTo baseDirectory: URL? = nil) throws -> EventPostRequest {
        if let path = try? decoder.decode(ActionTracePathRequest.self, from: body), !path.path.isEmpty {
            return try event(fromTraceAt: URL(fileURLWithPath: path.path))
        }

        let any = try JSONSerialization.jsonObject(with: body)
        guard let manifest = any as? [String: Any] else {
            throw HelperError("action trace body must be a JSON object")
        }
        return makeEvent(manifest: manifest, traceDirectory: baseDirectory)
    }

    /// Builds an event post body by reading an existing `trace.json` file.
    public func event(fromTraceAt traceURL: URL) throws -> EventPostRequest {
        let data = try Data(contentsOf: traceURL)
        let any = try JSONSerialization.jsonObject(with: data)
        guard let manifest = any as? [String: Any] else {
            throw HelperError("trace file must contain a JSON object: \(traceURL.path)")
        }
        return makeEvent(manifest: manifest, traceDirectory: traceURL.deletingLastPathComponent())
    }

    private func makeEvent(manifest: [String: Any], traceDirectory: URL?) -> EventPostRequest {
        let artifacts = manifest["artifacts"] as? [String: Any] ?? [:]
        let refs = artifactRefs(artifacts: artifacts, traceDirectory: traceDirectory)
        let payload = tracePayload(from: manifest, refs: refs)
        let target = (manifest["packageName"] as? String).map { "android:\($0)" }
        return EventPostRequest(
            target: target,
            source: "action",
            type: "action.trace",
            payload: payload,
            refs: refs
        )
    }

    private func tracePayload(from manifest: [String: Any], refs: [String: String]) -> [String: JSONValue] {
        var payload: [String: JSONValue] = [:]
        for key in ["traceVersion", "actionId", "packageName", "recordedAtMillis", "gesture"] {
            payload[key] = JSONValue.fromAny(manifest[key])
        }
        for key in ["selector", "target", "result"] {
            if let value = manifest[key] {
                payload[key] = JSONValue.fromAny(value)
            }
        }
        if let diff = manifest["diff"] as? [Any] {
            payload["changeCount"] = .number(Double(diff.count))
        }
        if !refs.isEmpty {
            payload["artifactRefs"] = JSONValue.fromAny(refs)
        }
        return payload
    }

    private func artifactRefs(artifacts: [String: Any], traceDirectory: URL?) -> [String: String] {
        var refs: [String: String] = [:]
        if let traceDirectory {
            refs["manifest"] = traceDirectory.appendingPathComponent("trace.json").path
        }
        for (key, value) in artifacts {
            guard let filename = value as? String else { continue }
            refs[key] = traceDirectory?.appendingPathComponent(filename).path ?? filename
        }
        return refs
    }
}

private struct ActionTracePathRequest: Decodable {
    let path: String
}
