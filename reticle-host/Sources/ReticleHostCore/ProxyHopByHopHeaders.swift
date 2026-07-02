import Foundation
import NIOHTTP1

enum ProxyHopByHopHeaders {
    private static let fixed = Set([
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "proxy-connection",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade"
    ])

    static func shouldForwardRequestHeader(_ name: String, in headers: HTTPHeaders) -> Bool {
        !headersToDrop(from: headers).contains(name.lowercased())
    }

    static func shouldForwardResponseHeader(_ name: String, in fields: [AnyHashable: Any]) -> Bool {
        !headersToDrop(from: fields).contains(name.lowercased())
    }

    private static func headersToDrop(from headers: HTTPHeaders) -> Set<String> {
        var names = fixed
        for connection in headers[canonicalForm: "connection"] {
            names.formUnion(tokens(in: String(connection)))
        }
        return names
    }

    private static func headersToDrop(from fields: [AnyHashable: Any]) -> Set<String> {
        var names = fixed
        for (name, value) in fields {
            guard let name = name as? String, name.lowercased() == "connection" else { continue }
            names.formUnion(tokens(in: "\(value)"))
        }
        return names
    }

    private static func tokens(in headerValue: String) -> [String] {
        headerValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
}
