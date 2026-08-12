import Foundation
import ReticleProtocol
import Synchronization
#if canImport(UIKit)
import UIKit
#endif

/// Process-wide singleton owning the server, the app-authored log ring, and the
/// metadata/probe registries. The iOS analogue of the Android `ReticleRuntime`.
final class ReticleRuntime: Sendable {
    static let shared = ReticleRuntime()

    /// Everything mutable, in one mutex. Held only for short reads/writes —
    /// never across the bind, which is what `startLock` is for.
    private struct State {
        var server: HttpServer?
        var boundPort: Int = -1
        var logs: [LogEntry] = []
        var metadataByTestId: [String: [String: MetadataValue]] = [:]
        var probes: [ProbeSpec] = []
    }
    private let state = Mutex(State())

    /// Serializes `start()` itself, so concurrent starts stay idempotent (one
    /// bind, everyone else observes it) WITHOUT holding `state` across the
    /// blocking bind: `HttpServer.start` waits up to 3s for the listener to
    /// become ready, and holding the state lock for that window stalled every
    /// thread calling `Reticle.log()` / `attachMetadata()` behind a wedged bind.
    private let startLock = Mutex<Void>(())

    private let maxLogs = 1000

    struct ProbeSpec: Sendable {
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
        // startLock (not `lock`) is held across the bind — see its declaration.
        return startLock.withLock { _ in startLocked(port: port, bindHost: bindHost, viaInjection: viaInjection) }
    }

    private func startLocked(port: Int?, bindHost: String, viaInjection: Bool) -> Int {
        let runningPort = state.withLock { state in
            (state.server?.isRunning == true) ? state.boundPort : nil
        }
        if let runningPort { return runningPort }
        if viaInjection && !autoStartAllowed() {
            return -1
        }
        let chosen = port ?? PortMap.derivePort(bundleId)
        let srv = HttpServer(router: Router())
        do {
            let bound = try srv.start(host: bindHost, port: chosen)
            state.withLock { state in
                state.server = srv
                state.boundPort = bound
            }
            engageAccessibilityRuntime()
            #if canImport(UIKit)
            // Install the keyboard observer as early as possible: it can only
            // report exact frames for keyboard events it has seen.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { KeyboardMonitor.shared.install() }
            }
            #endif
            NSLog("[Reticle] agent listening on \(bindHost):\(bound) for \(bundleId)")
            return bound
        } catch {
            NSLog("[Reticle] failed to start server on \(bindHost):\(chosen): \(error)")
            return -1
        }
    }

    /// Engage the accessibility runtime once at startup so SwiftUI builds its
    /// accessibility tree. On a real device SwiftUI populates `axElement`s (which
    /// carry `.accessibilityIdentifier`) lazily — only once an accessibility
    /// client is active — so without this the first (often every) device
    /// observation captures just the raw UIKit view tree and selector targeting
    /// silently misses. `_AXSSetAutomationEnabled(true)` is exactly the flag
    /// XCUITest sets to expose accessibility for automation, without VoiceOver
    /// and without firing any control. Done at startup (not first capture) so the
    /// tree is built by the time the host observes. Best-effort and guarded: a
    /// missing symbol is a no-op. (The simulator has it engaged via Simulator.app.)
    private func engageAccessibilityRuntime() {
        #if canImport(UIKit)
        guard let handle = dlopen("/usr/lib/libAccessibility.dylib", RTLD_NOW) else { return }
        typealias BoolGetter = @convention(c) () -> Bool
        typealias BoolSetter = @convention(c) (Bool) -> Void
        if let isOn = dlsym(handle, "_AXSAutomationEnabled"),
           unsafeBitCast(isOn, to: BoolGetter.self)() {
            return
        }
        guard let setter = dlsym(handle, "_AXSSetAutomationEnabled") else { return }
        unsafeBitCast(setter, to: BoolSetter.self)(true)
        NSLog("[Reticle] engaged accessibility runtime (automation enabled)")
        #endif
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
        let maxLogs = maxLogs
        state.withLock { state in
            state.logs.append(
                LogEntry(timestampMillis: nowMillis(), level: level, message: message, metadata: metadata))
            if state.logs.count > maxLogs { state.logs.removeFirst(state.logs.count - maxLogs) }
        }
    }

    func collectedLogs() -> [LogEntry] {
        state.withLock { $0.logs }
    }

    // MARK: - Metadata & probes

    func attachMetadata(testId: String, _ metadata: [String: MetadataValue]) {
        state.withLock { $0.metadataByTestId[testId, default: [:]].merge(metadata) { _, new in new } }
    }

    func metadata(for testId: String) -> [String: MetadataValue] {
        state.withLock { $0.metadataByTestId[testId] ?? [:] }
    }

    func registerProbe(testId: String, label: String?, frame: Rect?, metadata: [String: MetadataValue]) {
        state.withLock { state in
            state.probes.removeAll { $0.testId == testId }
            state.probes.append(ProbeSpec(testId: testId, label: label, frame: frame, metadata: metadata))
        }
    }

    func registeredProbes() -> [ProbeSpec] {
        state.withLock { $0.probes }
    }

    func clearProbes() {
        state.withLock { $0.probes.removeAll() }
    }

    // MARK: - Runtime info

    func runtimeInfo() -> RuntimeInfo {
        // boundPort is written under the mutex in start(); read it under the same
        // mutex — an unsynchronized read is a data race under the Swift memory model.
        let port = state.withLock { $0.boundPort }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return RuntimeInfo(
            packageName: bundleId,
            processName: ProcessInfo.processInfo.processName,
            pid: Int(getpid()),
            sdkInt: os.majorVersion,
            agentVersion: Reticle.version,
            port: port
        )
    }
}

func nowMillis() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000.0)
}
