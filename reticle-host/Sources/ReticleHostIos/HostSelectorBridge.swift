import Foundation
import ReticleHostShared
import ReticleProtocol

extension HostSelector {
    /// The protocol's own selector. `HostSelector` carries the host-side extras the
    /// protocol has no concept of (`alias`, which is a CLI/outline-cache affordance),
    /// so the two are not the same type; this is the narrowing.
    var protocolSelector: TargetSelector {
        TargetSelector(
            testId: testId,
            resourceId: resourceId,
            cssSelector: cssSelector,
            ref: ref,
            point: HostSelector.parsePoint(point),
            label: label,
            region: region
        )
    }

    static func parsePoint(_ raw: String?) -> Point? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
        return Point(x: x, y: y)
    }
}

extension MetadataValue {
    /// Coerce a CLI string into a metadata value (bool / int / real / text),
    /// matching how the Kotlin helper interprets `mutate --value`.
    static func parsed(from raw: String) -> MetadataValue {
        if raw == "true" || raw == "false" { return .bool(raw == "true") }
        if let i = Int64(raw) { return .integer(i) }
        if let d = Double(raw) { return .real(d) }
        return .text(raw)
    }
}
