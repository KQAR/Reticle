import Foundation
import NIOHTTP1

/// Produces display-safe HTTP header dictionaries for network events.
enum NetworkHeaders {
    private static let redactedNames = Set([
        "authorization",
        "cookie",
        "proxy-authorization",
        "set-cookie",
        "x-api-key"
    ])

    /// Converts NIO headers into a JSON-friendly map with sensitive values redacted.
    static func request(_ headers: HTTPHeaders) -> [String: String] {
        sanitize(headers.map { ($0.name, $0.value) })
    }

    /// Converts URL response headers into a JSON-friendly map with sensitive values redacted.
    static func response(_ headers: [AnyHashable: Any]) -> [String: String] {
        sanitize(headers.compactMap { key, value in
            guard let name = key as? String else { return nil }
            return (name, "\(value)")
        })
    }

    private static func sanitize(_ headers: [(String, String)]) -> [String: String] {
        var result: [String: String] = [:]
        for (name, value) in headers {
            result[name] = redactedNames.contains(name.lowercased()) ? "<redacted>" : value
        }
        return result
    }
}
