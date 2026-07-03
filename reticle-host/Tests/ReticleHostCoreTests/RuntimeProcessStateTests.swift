import Foundation
import Testing
@testable import ReticleHostCore

@Suite("Runtime process state")
struct RuntimeProcessStateTests {
    @Test func firstObservationRecordsWithoutAdvisory() throws {
        let store = RuntimeProcessStateStore(fileURL: try stateFile())

        let advisory = store.observe(
            package: "pkg",
            serial: nil,
            result: ["running": true, "pid": 10, "runtime": "healthy"]
        )

        #expect(advisory == nil)
    }

    @Test func pidChangeProducesRestartAdvisory() throws {
        let store = RuntimeProcessStateStore(fileURL: try stateFile())
        _ = store.observe(package: "pkg", serial: "device", result: ["running": true, "pid": 10, "runtime": "healthy"])

        let advisory = store.observe(
            package: "pkg",
            serial: "device",
            result: ["running": true, "pid": 11, "runtime": "healthy"]
        )

        #expect(advisory?.kind == "process-restarted")
        #expect(advisory?.previousPid == 10)
        #expect(advisory?.currentPid == 11)
        #expect(advisory?.jsonObject["kind"] as? String == "process-restarted")
    }

    @Test func healthyRuntimeRegressionProducesAdvisory() throws {
        let store = RuntimeProcessStateStore(fileURL: try stateFile())
        _ = store.observe(package: "pkg", serial: nil, result: ["running": true, "pid": 10, "runtime": "healthy"])

        let advisory = store.observe(
            package: "pkg",
            serial: nil,
            result: ["running": true, "pid": 10, "runtime": "unreachable"]
        )

        #expect(advisory?.kind == "runtime-degraded")
        #expect(advisory?.previousRuntime == "healthy")
        #expect(advisory?.currentRuntime == "unreachable")
    }

    @Test func explicitRecordRefreshesBaselineWithoutAdvisory() throws {
        let store = RuntimeProcessStateStore(fileURL: try stateFile())
        _ = store.observe(package: "pkg", serial: nil, result: ["running": true, "pid": 10, "runtime": "healthy"])

        store.record(package: "pkg", serial: nil, result: ["pid": 11, "packageName": "pkg"])
        let advisory = store.observe(package: "pkg", serial: nil, result: ["running": true, "pid": 11, "runtime": "healthy"])

        #expect(advisory == nil)
    }

    private func stateFile() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("process-state.json")
    }
}
