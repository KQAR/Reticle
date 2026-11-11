import Foundation
import ReticleProtocol

/// Reading the `act` parameter dictionary — the pieces every platform's
/// orchestration needs. `act batch` builds steps from user JSON, so the shared
/// layer reads the same stringly shape the backends do.
public enum ActParams {
    /// Interpret a CLI / batch-step boolean (`true`, `"true"`, `1`) as a flag.
    public static func isTruthy(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: return b
        case let s as String: return s == "true" || s == "1"
        case let n as NSNumber: return n.boolValue
        default: return false
        }
    }

    public static func selector(_ params: [String: Any]) -> ReticleProtocol.Selector {
        ReticleProtocol.Selector(
            testId: params["testId"] as? String,
            resourceId: params["resourceId"] as? String,
            cssSelector: params["css"] as? String,
            ref: params["ref"] as? String,
            point: point(params["point"]),
            label: params["label"] as? String,
            region: params["region"] as? String
        )
    }

    /// `x,y` → a point; anything else → nil.
    public static func point(_ raw: Any?) -> Point? {
        guard let s = raw as? String else { return nil }
        let parts = s.split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return Point(x: x, y: y)
    }
}

/// Fetch one live snapshot of the app under test. The one platform seam every
/// observing loop here needs.
public typealias SnapshotFetch = () async throws -> Snapshot
