import Foundation

public struct RuntimeProcessAdvisory: Codable, Equatable {
    public let kind: String
    public let message: String
    public let previousPid: Int?
    public let currentPid: Int?
    public let previousRuntime: String?
    public let currentRuntime: String?

    var jsonObject: [String: Any] {
        var value: [String: Any] = [
            "kind": kind,
            "message": message,
        ]
        if let previousPid { value["previousPid"] = previousPid }
        if let currentPid { value["currentPid"] = currentPid }
        if let previousRuntime { value["previousRuntime"] = previousRuntime }
        if let currentRuntime { value["currentRuntime"] = currentRuntime }
        return value
    }
}

public final class RuntimeProcessStateStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL = RuntimeProcessStateStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        DaemonDiscovery.reticleHome().appendingPathComponent("process-state.json")
    }

    @discardableResult
    public func observe(package: String, serial: String?, result: [String: Any]) -> RuntimeProcessAdvisory? {
        guard let current = RuntimeProcessObservation(package: package, serial: serial, result: result) else {
            return nil
        }
        return update(with: current, reportAdvisory: true)
    }

    public func record(package: String, serial: String?, result: [String: Any], runtime: String = "healthy") {
        var result = result
        result["running"] = true
        result["runtime"] = runtime
        guard let current = RuntimeProcessObservation(package: package, serial: serial, result: result) else {
            return
        }
        _ = update(with: current, reportAdvisory: false)
    }

    private func update(with current: RuntimeProcessObservation, reportAdvisory: Bool) -> RuntimeProcessAdvisory? {
        lock.lock()
        defer { lock.unlock() }
        var state = readState()
        let key = current.key
        let previous = state.entries[key]
        state.entries[key] = current.record
        writeState(state)
        guard reportAdvisory, let previous else { return nil }
        return advisory(previous: previous, current: current.record)
    }

    private func advisory(
        previous: RuntimeProcessRecord,
        current: RuntimeProcessRecord
    ) -> RuntimeProcessAdvisory? {
        if previous.running, !current.running {
            return RuntimeProcessAdvisory(
                kind: "process-stopped",
                message: "app process stopped since the last Reticle observation",
                previousPid: previous.pid,
                currentPid: current.pid,
                previousRuntime: previous.runtime,
                currentRuntime: current.runtime
            )
        }
        if let old = previous.pid, let new = current.pid, old != new {
            return RuntimeProcessAdvisory(
                kind: "process-restarted",
                message: "app process pid changed since the last Reticle observation",
                previousPid: old,
                currentPid: new,
                previousRuntime: previous.runtime,
                currentRuntime: current.runtime
            )
        }
        if previous.runtime == "healthy", let runtime = current.runtime, runtime != "healthy" {
            return RuntimeProcessAdvisory(
                kind: "runtime-degraded",
                message: "Reticle runtime changed from healthy to \(runtime)",
                previousPid: previous.pid,
                currentPid: current.pid,
                previousRuntime: previous.runtime,
                currentRuntime: runtime
            )
        }
        return nil
    }

    private func readState() -> RuntimeProcessStateFile {
        guard
            let data = try? Data(contentsOf: fileURL),
            let state = try? JSONDecoder().decode(RuntimeProcessStateFile.self, from: data)
        else {
            return RuntimeProcessStateFile(entries: [:])
        }
        return state
    }

    private func writeState(_ state: RuntimeProcessStateFile) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            FileHandle.standardError.write(Data("warning: could not write process state: \(error)\n".utf8))
        }
    }
}

private struct RuntimeProcessStateFile: Codable {
    var entries: [String: RuntimeProcessRecord]
}

private struct RuntimeProcessObservation {
    let key: String
    let record: RuntimeProcessRecord

    init?(package: String, serial: String?, result: [String: Any]) {
        let running = boolValue(result["running"]) ?? (intValue(result["pid"]) != nil)
        let pid = intValue(result["pid"])
        let runtime = result["runtime"] as? String
        guard running || pid != nil || runtime != nil else { return nil }
        let serialKey = serial?.isEmpty == false ? serial! : "default"
        key = "\(serialKey)|\(package)"
        record = RuntimeProcessRecord(
            package: package,
            serial: serial,
            running: running,
            pid: pid,
            runtime: runtime,
            observedAtMillis: currentMillis()
        )
    }
}

private struct RuntimeProcessRecord: Codable, Equatable {
    let package: String
    let serial: String?
    let running: Bool
    let pid: Int?
    let runtime: String?
    let observedAtMillis: Int64
}

private func boolValue(_ any: Any?) -> Bool? {
    switch any {
    case let value as Bool:
        return value
    case let value as NSNumber:
        return value.boolValue
    default:
        return nil
    }
}

private func intValue(_ any: Any?) -> Int? {
    switch any {
    case let value as Int:
        return value
    case let value as Int64:
        return Int(value)
    case let value as Double:
        return Int(value)
    case let value as NSNumber:
        return value.intValue
    default:
        return nil
    }
}
