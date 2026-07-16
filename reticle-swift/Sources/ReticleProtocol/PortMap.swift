import Foundation

/// Deterministic loopback-port assignment, computed identically to reticle-core's
/// `PortMap` (FNV-1a 32-bit over the UTF-8 bytes of the app id). The agent binds
/// `derivePort(bundleId)` and the host connects to the same value, so no
/// discovery round-trip is needed. This is a protocol rule each end implements
/// independently — it is intentionally NOT shared code across languages.
public enum PortMap {
    /// Base of the assigned range; also the historical default port.
    public static let basePort = 8765

    /// Number of distinct ports in the range [basePort, basePort + range).
    public static let range = 1000

    /// The loopback port the agent for `appId` binds and the host connects to.
    /// Falls back to `basePort` for a blank id.
    public static func derivePort(_ appId: String) -> Int {
        let trimmed = appId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return basePort }
        let h = fnv1a32(appId)
        let offset = Int(UInt64(h) % UInt64(range))
        return basePort + offset
    }

    /// 32-bit FNV-1a over the UTF-8 bytes of `s`, using wrapping arithmetic so it
    /// matches the Kotlin `Int` overflow behavior exactly.
    static func fnv1a32(_ s: String) -> UInt32 {
        var hash: UInt32 = 0x811C9DC5 // FNV offset basis
        for b in Array(s.utf8) {
            hash ^= UInt32(b)
            hash = hash &* 0x01000193 // FNV prime, wrapping multiply
        }
        return hash
    }
}
