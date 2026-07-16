import Foundation
import ReticleProtocol
#if canImport(UIKit)
import UIKit
#endif

/// Process-wide singleton owning the server, the app-authored log ring, and the
/// metadata/probe registries. The iOS analogue of the Android `ReticleRuntime`.
final class ReticleRuntime: @unchecked Sendable {
    static let shared = ReticleRuntime()

    private let lock = NSLock()
    private var server: HttpServer?
    private(set) var boundPort: Int = -1

    private var logs: [LogEntry] = []
    private let maxLogs = 1000
    private var metadataByTestId: [String: [String: MetadataValue]] = [:]
    private var probes: [ProbeSpec] = []

    struct ProbeSpec {
        let testId: String
        let label: String?
        let frame: Rect?
        let metadata: [String: MetadataValue]
    }

    private init() {}

    var bundleId: String {
        Bundle.main.bundleIdentifier ?? ""
    }

    /// Idempotent start. Returns the bound port, or a negative value on failure /
    /// when gated off.
    @discardableResult
    func start(port: Int?, bindHost: String, viaInjection: Bool) -> Int {
        if ProcessInfo.processInfo.environment["RETICLE_DISABLED"] == "1" { return -1 }
        lock.lock()
        if let server, server.isRunning {
            let p = boundPort
            lock.unlock()
            return p
        }
        if viaInjection && !autoStartAllowed() {
            lock.unlock()
            return -1
        }
        let chosen = port ?? PortMap.derivePort(bundleId)
        let srv = HttpServer(router: Router())
        do {
            let bound = try srv.start(host: bindHost, port: chosen)
            server = srv
            boundPort = bound
            lock.unlock()
            NSLog("[Reticle] agent listening on \(bindHost):\(bound) for \(bundleId)")
            return bound
        } catch {
            lock.unlock()
            NSLog("[Reticle] failed to start server on \(bindHost):\(chosen): \(error)")
            return -1
        }
    }

    /// Auto-start gate for the injection path. Allowed when explicitly enabled via
    /// env or Info.plist, or in a DEBUG build. This keeps the unauthenticated
    /// loopback server out of a shipped release that merely links the framework.
    private func autoStartAllowed() -> Bool {
        if ProcessInfo.processInfo.environment["RETICLE_PORT"] != nil { return true }
        if (Bundle.main.object(forInfoDictionaryKey: "ReticleAgentEnabled") as? Bool) == true { return true }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    // MARK: - Logs

    func appendLog(level: String, message: String, metadata: [String: MetadataValue]) {
        lock.lock(); defer { lock.unlock() }
        logs.append(LogEntry(timestampMillis: nowMillis(), level: level, message: message, metadata: metadata))
        if logs.count > maxLogs { logs.removeFirst(logs.count - maxLogs) }
    }

    func collectedLogs() -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return logs
    }

    // MARK: - Metadata & probes

    func attachMetadata(testId: String, _ metadata: [String: MetadataValue]) {
        lock.lock(); defer { lock.unlock() }
        metadataByTestId[testId, default: [:]].merge(metadata) { _, new in new }
    }

    func metadata(for testId: String) -> [String: MetadataValue] {
        lock.lock(); defer { lock.unlock() }
        return metadataByTestId[testId] ?? [:]
    }

    func registerProbe(testId: String, label: String?, frame: Rect?, metadata: [String: MetadataValue]) {
        lock.lock(); defer { lock.unlock() }
        probes.removeAll { $0.testId == testId }
        probes.append(ProbeSpec(testId: testId, label: label, frame: frame, metadata: metadata))
    }

    func registeredProbes() -> [ProbeSpec] {
        lock.lock(); defer { lock.unlock() }
        return probes
    }

    // MARK: - Runtime info

    func runtimeInfo() -> RuntimeInfo {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return RuntimeInfo(
            packageName: bundleId,
            processName: ProcessInfo.processInfo.processName,
            pid: Int(getpid()),
            sdkInt: os.majorVersion,
            agentVersion: Reticle.version,
            port: boundPort
        )
    }
}

func nowMillis() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000.0)
}
