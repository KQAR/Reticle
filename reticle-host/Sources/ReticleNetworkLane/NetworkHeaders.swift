import Foundation

/// Produces display-safe HTTP header dictionaries for network events.
enum NetworkHeaders {
    private static let redactedNames = Set([
        "authorization",
        "cookie",
        "proxy-authorization",
        "set-cookie",
        "x-api-key"
    ])

    /// Redacts an ordered list of raw `(name, value)` header pairs — the capture
    /// backend (`LoomCaptureLane`) surfaces headers as ordered pairs, so redaction
    /// stays defined in one place.
    static func redacted(pairs: [(name: String, value: String)]) -> [String: String] {
        sanitize(pairs.map { ($0.name, $0.value) })
    }

    private static func sanitize(_ headers: [(String, String)]) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in headers {
            result[name] = redactedNames.contains(name.lowercased()) ? "<redacted>" : value
        }
        return result
    }
}
