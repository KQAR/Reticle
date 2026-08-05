import Foundation

/// The host's release version.
///
/// Lives in the shared foundation layer, not in the CLI, because three layers
/// answer with it: the CLI's `version` command, the resident helper daemon's
/// staleness check, and a platform backend's `ping`. Anchoring it under the CLI
/// made the iOS backend depend on the CLI just to name itself.
public enum ReticleVersion {
    public static let current = "0.18.0"
}

/// Minimal call surface every helper backend implements — a local helper process,
/// a daemon-forwarded RPC, or a natively in-host platform (iOS).
///
/// Lives below both the CLI and the platform backends on purpose: the CLI's
/// commands are written against this protocol, and a backend must be able to
/// implement it without reaching up into the CLI. The stringly-typed shape is the
/// Android helper's wire contract (see reticle-protocol/helper-rpc.md) and is
/// tracked for a typed replacement; keeping it here at least stops the shape from
/// dragging a target dependency along with it.
public protocol HelperCalling: AnyObject, Sendable {
    @discardableResult
    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any]

    /// Releases whatever transport this client holds. Every backend has one
    /// caller-visible lifecycle so command dispatch can `defer` it uniformly
    /// instead of knowing which of `shutdown()` / `close()` / nothing applies.
    /// Default no-op: an in-host or request-per-call backend owns nothing.
    func close()
}

public extension HelperCalling {
    @discardableResult
    func call(_ method: String) throws -> [String: Any] {
        try call(method, [:])
    }

    func close() {}
}
