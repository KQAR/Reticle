import Foundation

/// Shared JSON configuration, the Swift counterpart of reticle-core's
/// `ReticleJson`. The omit-defaults behavior lives in each type's custom
/// `encode(to:)` (Swift has no global `encodeDefaults=false`), so these encoders
/// only choose formatting. `wire` is minified for HTTP/RPC; `pretty` is for
/// on-disk artifacts.
public enum ReticleJSON {
    public static let wire: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()

    public static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static let decoder = JSONDecoder()

    /// Minified UTF-8 JSON for the wire.
    public static func encodeWire<T: Encodable>(_ value: T) throws -> Data {
        try wire.encode(value)
    }

    /// Pretty UTF-8 JSON for on-disk artifacts.
    public static func encodePretty<T: Encodable>(_ value: T) throws -> Data {
        try pretty.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        try decoder.decode(type, from: Data(string.utf8))
    }
}
