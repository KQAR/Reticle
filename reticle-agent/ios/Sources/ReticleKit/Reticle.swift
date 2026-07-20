import Foundation
import ReticleProtocol

/// The public, app-facing facade for the iOS agent — the analogue of the Android
/// `Reticle` object. Linked apps call `Reticle.start()`; the DYLD-injection path
/// calls `startFromInjection()` from the C bootstrap.
public enum Reticle {
    /// Agent build version reported in `RuntimeInfo.agentVersion`.
    public static let version = "0.8.0"

    /// Start the in-process server (the "linked" path). Explicit, so it always
    /// starts regardless of build configuration — the app opted in by calling it.
    /// - Parameters:
    ///   - port: overrides the derived port; `nil` uses `PortMap.derivePort(bundleId)`.
    ///   - bindHost: loopback host to bind; defaults to 127.0.0.1.
    @discardableResult
    public static func start(port: Int? = nil, bindHost: String = "127.0.0.1") -> Int {
        ReticleRuntime.shared.start(port: port, bindHost: bindHost, viaInjection: false)
    }

    /// Entry for the injection path. Gated (see `ReticleRuntime.autoStartAllowed`)
    /// and deferred to the main thread so it runs after the app is up.
    public static func startFromInjection() {
        DispatchQueue.main.async {
            _ = ReticleRuntime.shared.start(
                port: envPort(),
                bindHost: ProcessInfo.processInfo.environment["RETICLE_BIND_HOST"] ?? "127.0.0.1",
                viaInjection: true
            )
        }
    }

    // MARK: - App-authored bridge

    /// Append an app-authored log line, surfaced through `/logs`.
    public static func log(_ message: String, level: String = "info", metadata: [String: MetadataValue] = [:]) {
        ReticleRuntime.shared.appendLog(level: level, message: message, metadata: metadata)
    }

    /// Attach scalar metadata to a node identified by its `testId`; merged into
    /// that node's `custom` map at capture time.
    public static func attachMetadata(testId: String, _ metadata: [String: MetadataValue]) {
        ReticleRuntime.shared.attachMetadata(testId: testId, metadata)
    }

    /// Register a synthetic probe node (e.g. to anchor a SwiftUI element that has
    /// no addressable accessibility identity).
    public static func registerProbe(testId: String, label: String? = nil, frame: Rect? = nil, metadata: [String: MetadataValue] = [:]) {
        ReticleRuntime.shared.registerProbe(testId: testId, label: label, frame: frame, metadata: metadata)
    }

    private static func envPort() -> Int? {
        if let s = ProcessInfo.processInfo.environment["RETICLE_PORT"], let p = Int(s) { return p }
        return nil
    }
}
