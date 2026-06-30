import Foundation
import NIOHTTP1

/// Parsed upstream destination for a proxied request.
struct HTTPProxyTarget {
    let url: URL
    let scheme: String
    let host: String
    let port: Int
    let path: String

    /// Parses either absolute-form proxy URIs or origin-form URIs with Host.
    init?(head: HTTPRequestHead, defaultScheme: String) {
        if let absolute = URL(string: head.uri), let scheme = absolute.scheme, let host = absolute.host {
            self.init(url: absolute, scheme: scheme, host: host, port: absolute.port ?? Self.defaultPort(scheme), path: absolute.pathWithQuery)
            return
        }
        guard let hostHeader = head.headers.first(name: "Host") else { return nil }
        let (host, port) = Self.splitHostPort(hostHeader, defaultPort: Self.defaultPort(defaultScheme))
        guard let url = URL(string: "\(defaultScheme)://\(hostHeader)\(head.uri)") else { return nil }
        self.init(url: url, scheme: defaultScheme, host: host, port: port, path: head.uri)
    }

    /// Parses the `host:port` value carried by CONNECT.
    init?(connectTarget: String) {
        let (host, port) = Self.splitHostPort(connectTarget, defaultPort: 443)
        guard !host.isEmpty, let url = URL(string: "https://\(host):\(port)") else { return nil }
        self.init(url: url, scheme: "https", host: host, port: port, path: "")
    }

    private init(url: URL, scheme: String, host: String, port: Int, path: String) {
        self.url = url
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path.isEmpty ? "/" : path
    }

    /// Creates event payload metadata for this target.
    func payload(requestId: String, method: String, start: Int64, tunnel: Bool, mitm: Bool) -> NetworkEventPayload {
        NetworkEventPayload(
            requestId: requestId,
            scheme: scheme,
            method: method,
            url: url.absoluteString,
            host: host,
            port: port,
            path: path,
            startMillis: start,
            tunnel: tunnel,
            mitm: mitm
        )
    }

    private static func defaultPort(_ scheme: String) -> Int {
        scheme == "https" ? 443 : 80
    }

    private static func splitHostPort(_ value: String, defaultPort: Int) -> (String, Int) {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let port = Int(parts[1]) else {
            return (String(parts.first ?? ""), defaultPort)
        }
        return (String(parts[0]), port)
    }
}

private extension URL {
    var pathWithQuery: String {
        var value = path.isEmpty ? "/" : path
        if let query { value += "?\(query)" }
        return value
    }
}
