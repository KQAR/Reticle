import Foundation
import ReticleProtocol

// Reading the RPC parameter dictionary: flags, selectors, points, metadata values.
//
// This is the seam the stringly-typed `HelperCalling` shape forces on a native
// backend — every command's arguments arrive as `[String: Any]` and must be picked
// apart by hand. Collected in one file so the cost is visible in one place rather
// than smeared through the command handlers, and so a typed replacement has an
// obvious blast radius.
extension IosHelperClient {
    // MARK: - Selector / value helpers

    /// Interpret a CLI / batch-step boolean (`true`, `"true"`, `1`) as a flag.
    func isTruthy(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: return b
        case let s as String: return s == "true" || s == "1"
        case let n as NSNumber: return n.boolValue
        default: return false
        }
    }

    func selectorFromParams(_ params: [String: Any]) -> TargetSelector {
        TargetSelector(
            testId: params["testId"] as? String,
            resourceId: params["resourceId"] as? String,
            cssSelector: params["css"] as? String,
            ref: params["ref"] as? String,
            point: parsePoint(params["point"]),
            label: params["label"] as? String,
            region: params["region"] as? String
        )
    }

    /// Coerce a CLI string value into a MetadataValue (bool / int / real / text),
    /// matching how the Kotlin helper interprets `mutate --value`.
    func metadataValue(from raw: Any?) -> MetadataValue {
        guard let s = raw as? String else {
            if let b = raw as? Bool { return .bool(b) }
            if let i = raw as? Int { return .integer(Int64(i)) }
            if let d = raw as? Double { return .real(d) }
            return .text("\(raw ?? "")")
        }
        if s == "true" || s == "false" { return .bool(s == "true") }
        if let i = Int64(s) { return .integer(i) }
        if let d = Double(s) { return .real(d) }
        return .text(s)
    }
}
