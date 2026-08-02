import Foundation

/// Scalar metadata value, serialized with a `_type` discriminator carrying a
/// short language-neutral tag (`text`/`bool`/`int`/`real`) and the payload under
/// `value`. Mirrors the sealed `MetadataValue` in reticle-core; the tags must
/// stay in lockstep with the schema enum.
public enum MetadataValue: Codable, Equatable, Sendable {
    case text(String)
    case bool(Bool)
    case integer(Int64)
    case real(Double)

    private enum CodingKeys: String, CodingKey {
        case type = "_type"
        case value
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let v):
            try c.encode("text", forKey: .type)
            try c.encode(v, forKey: .value)
        case .bool(let v):
            try c.encode("bool", forKey: .type)
            try c.encode(v, forKey: .value)
        case .integer(let v):
            try c.encode("int", forKey: .type)
            try c.encode(v, forKey: .value)
        case .real(let v):
            try c.encode("real", forKey: .type)
            try c.encode(v, forKey: .value)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(String.self, forKey: .type)
        switch tag {
        case "text": self = .text(try c.decode(String.self, forKey: .value))
        case "bool": self = .bool(try c.decode(Bool.self, forKey: .value))
        case "int": self = .integer(try c.decode(Int64.self, forKey: .value))
        case "real": self = .real(try c.decode(Double.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "unknown MetadataValue _type tag: \(tag)")
        }
    }

    public func displayString() -> String {
        switch self {
        case .text(let v): return v
        case .bool(let v): return String(v)
        case .integer(let v): return String(v)
        case .real(let v): return Self.canonicalRealString(v)
        }
    }

    /// Canonical spelling of a `real`, so the two agents render the same value
    /// the same way.
    ///
    /// `displayString()` feeds `verify --custom` matching and trace diffs, so a
    /// property captured on Android and the same property captured on iOS have
    /// to spell identically. Both languages emit round-tripping digits but dress
    /// them differently: Swift writes `1e+17` / `inf` / `nan` / `1e-05`, Kotlin
    /// writes `1.0E17` / `Infinity` / `NaN` / `1.0E-5`. The Kotlin/Java form is
    /// the canonical one — it is specified (`java.lang.Double.toString`) where
    /// Swift's is not — so this re-dresses Swift's output into it: plain decimal
    /// with at least one fraction digit when `1e-3 <= |v| < 1e7`, scientific
    /// `d.dddEn` otherwise.
    ///
    /// Residual boundary: for a handful of subnormals the two runtimes pick a
    /// different *digit* string (Java may print `4.9E-324` where Swift's
    /// shortest round-trip is `5E-324`). Only the formatting is unified here,
    /// not the digit-selection algorithm.
    public static func canonicalRealString(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        let sign = value.sign == .minus ? "-" : ""
        if value == 0 { return sign + "0.0" }

        let raw = String(abs(value))
        var mantissa = Substring(raw)
        var exponent = 0
        if let e = raw.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = raw[raw.startIndex..<e]
            exponent = Int(raw[raw.index(after: e)...]) ?? 0
        }
        var integerPart = mantissa
        var fractionPart = Substring("")
        if let dot = mantissa.firstIndex(of: ".") {
            integerPart = mantissa[mantissa.startIndex..<dot]
            fractionPart = mantissa[mantissa.index(after: dot)...]
        }

        var digits = Array(integerPart) + Array(fractionPart)
        // Digits that belong before the decimal point once the exponent is folded in.
        var pointPosition = integerPart.count + exponent

        var leading = 0
        while leading < digits.count && digits[leading] == "0" { leading += 1 }
        if leading == digits.count { return sign + "0.0" }
        digits.removeFirst(leading)
        pointPosition -= leading
        while digits.count > 1 && digits.last == "0" { digits.removeLast() }

        let magnitude = pointPosition - 1  // value == d0.d1... x 10^magnitude
        if magnitude >= -3 && magnitude < 7 {
            if pointPosition <= 0 {
                return sign + "0." + String(repeating: "0", count: -pointPosition) + String(digits)
            }
            if pointPosition >= digits.count {
                return sign + String(digits)
                    + String(repeating: "0", count: pointPosition - digits.count) + ".0"
            }
            return sign + String(digits[0..<pointPosition]) + "." + String(digits[pointPosition...])
        }
        let tail = digits.count > 1 ? String(digits[1...]) : "0"
        return sign + String(digits[0]) + "." + tail + "E" + String(magnitude)
    }
}
