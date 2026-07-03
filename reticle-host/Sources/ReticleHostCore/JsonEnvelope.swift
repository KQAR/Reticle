import Foundation

/// Canonical machine-readable CLI envelope.
///
/// Text output remains the default UX. `--json` switches successful commands to
/// `{ "ok": true, "data": ... }` and failures to `{ "ok": false, "error": ... }`
/// so agents can consume every helper-backed command with one parser.
public enum JsonEnvelope {
    public static func enabled(_ args: Args) -> Bool {
        args.option("json") != nil
    }

    public static func success(_ data: Any = [:], to handle: FileHandle = .standardOutput) throws {
        try write(["ok": true, "data": jsonSafe(data)], to: handle)
    }

    public static func error(_ error: Error, to handle: FileHandle = .standardOutput) {
        let message: String
        if let helper = error as? HelperError {
            message = helper.message
        } else {
            message = String(describing: error)
        }
        try? write(["ok": false, "error": message], to: handle)
    }

    public static func encodeSuccess(_ data: Any = [:]) throws -> Data {
        try encode(["ok": true, "data": jsonSafe(data)])
    }

    public static func encodeError(_ error: Error) throws -> Data {
        let message = (error as? HelperError)?.message ?? String(describing: error)
        return try encode(["ok": false, "error": message])
    }

    private static func write(_ object: Any, to handle: FileHandle) throws {
        let data = try encode(object)
        handle.write(data)
        handle.write(Data([0x0A]))
    }

    private static func encode(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues(jsonSafe)
        case let array as [Any]:
            return array.map(jsonSafe)
        case let value as String:
            return value
        case let value as Bool:
            return value
        case let value as Int:
            return value
        case let value as Int64:
            return value
        case let value as Double:
            return value
        case let value as Float:
            return Double(value)
        case is NSNull:
            return value
        case Optional<Any>.none:
            return NSNull()
        default:
            return String(describing: value)
        }
    }
}
