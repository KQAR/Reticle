import Foundation

/// Runtime configuration for the host network proxy owned by `reticle serve`.
public struct NetworkProxyConfiguration {
    public static let defaultMaxRequestBodyBytes = 64 * 1024 * 1024

    let port: Int
    /// Interface to bind. Defaults to loopback; a real device on Wi-Fi must reach
    /// the Mac over the LAN, so real-device capture binds `0.0.0.0` (or the LAN
    /// IP) — an explicit opt-in, since it exposes the MITM proxy on the network.
    let bindHost: String
    let target: String?
    let bodyLimitBytes: Int
    /// Ceiling on how much of one request body the proxy will buffer in memory
    /// before forwarding (the upstream forward needs the whole body today).
    /// Oversized uploads are rejected with 413 + a `network.error` event
    /// instead of ballooning the daemon — a safety valve against multi-GB
    /// uploads, not a tight bound; the default clears photo/video uploads.
    let maxRequestBodyBytes: Int
    let upstreamTimeoutSeconds: TimeInterval
    let mitmEnabled: Bool
    let caDirectory: URL?
    let tlsHostAllowlist: [String]

    /// Creates a proxy configuration with conservative defaults.
    public init(
        port: Int,
        bindHost: String = "127.0.0.1",
        target: String? = nil,
        bodyLimitBytes: Int = 1024 * 1024,
        maxRequestBodyBytes: Int = NetworkProxyConfiguration.defaultMaxRequestBodyBytes,
        upstreamTimeoutSeconds: TimeInterval = 30,
        mitmEnabled: Bool = false,
        caDirectory: URL? = nil,
        tlsHostAllowlist: [String] = []
    ) {
        self.port = port
        self.bindHost = bindHost
        self.target = target
        self.bodyLimitBytes = bodyLimitBytes
        self.maxRequestBodyBytes = maxRequestBodyBytes
        self.upstreamTimeoutSeconds = upstreamTimeoutSeconds
        self.mitmEnabled = mitmEnabled
        self.caDirectory = caDirectory
        self.tlsHostAllowlist = tlsHostAllowlist
    }
}

/// Explicit host policy for optional TLS interception.
struct TlsInterceptionPolicy {
    let enabled: Bool
    let allowlist: [String]

    /// Returns true only when TLS interception is explicitly enabled for `host`.
    func allows(host: String) -> Bool {
        guard enabled else { return false }
        let lower = host.lowercased()
        return allowlist.contains { rule in
            let rule = rule.lowercased()
            if rule.hasPrefix("*.") {
                return lower.hasSuffix(String(rule.dropFirst()))
            }
            return lower == rule
        }
    }
}

enum NetworkProxyError: Error, CustomStringConvertible {
    case caMaterialMissing(String)
    case startTimedOut

    var description: String {
        switch self {
        case .caMaterialMissing(let message):
            "proxy CA material is incomplete: \(message)"
        case .startTimedOut:
            "network proxy did not report a listening socket within 30 seconds"
        }
    }
}
