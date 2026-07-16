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
        case .real(let v): return String(v)
        }
    }
}
