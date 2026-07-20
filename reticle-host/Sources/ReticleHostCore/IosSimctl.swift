import Foundation

/// Thin wrapper over `xcrun simctl` — the iOS device-control seam (the analogue
/// of Android's `Adb`). Shells out; owns no long-lived state.
struct Simctl {
    struct Device {
        let udid: String
        let name: String
        let state: String
        let runtime: String
    }

    enum SimctlError: Error, CustomStringConvertible {
        case failed(String)
        case noBootedDevice
        var description: String {
            switch self {
            case .failed(let m): return m
            case .noBootedDevice: return "no booted simulator; boot one (xcrun simctl boot <udid>) or pass --serial <udid>"
            }
        }
    }

    /// Run `xcrun simctl <args>` and return (stdout, stderr, exitCode).
    @discardableResult
    static func run(_ args: [String], env extraEnv: [String: String] = [:]) throws -> (out: String, err: String, code: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + args
        if !extraEnv.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnv { env[k] = v }
            process.environment = env
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        // Drain both pipes concurrently. Reading stdout fully before touching
        // stderr deadlocks when a chatty subcommand fills stderr's ~64KB pipe
        // buffer while we're still blocked on stdout (the reason Android's Adb
        // drains on separate threads). Read stderr off-thread, stdout here.
        let errHandle = errPipe.fileHandleForReading
        let errBox = ResultBox<Data>(fallback: .success(Data()))
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errBox.set(.success(errHandle.readDataToEndOfFile()))
            errDone.signal()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        let errData = (try? errBox.value.get()) ?? Data()
        process.waitUntilExit()
        return (
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self),
            process.terminationStatus
        )
    }

    /// All simulator devices across runtimes (from `simctl list -j devices`).
    /// Throws on a real failure (non-zero `simctl`, unparseable JSON) so the true
    /// cause (Xcode not selected, `xcrun` broken, …) surfaces instead of being
    /// masked as "no booted simulator". Returns [] only for a valid, empty list.
    static func listDevices() throws -> [Device] {
        let r = try run(["list", "-j", "devices"])
        guard r.code == 0 else {
            throw SimctlError.failed("simctl list failed: \(r.err.isEmpty ? r.out : r.err)")
        }
        guard let data = r.out.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = root["devices"] as? [String: Any] else {
            throw SimctlError.failed("could not parse `simctl list -j devices` output")
        }
        var out: [Device] = []
        for (runtime, list) in byRuntime {
            guard let entries = list as? [[String: Any]] else { continue }
            for e in entries {
                guard let udid = e["udid"] as? String else { continue }
                out.append(Device(
                    udid: udid,
                    name: (e["name"] as? String) ?? "",
                    state: (e["state"] as? String) ?? "Unknown",
                    runtime: runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
                ))
            }
        }
        return out
    }

    /// Resolve a device: an explicit udid, else the (single) booted simulator.
    static func resolveUdid(_ serial: String?) throws -> String {
        if let serial, !serial.isEmpty { return serial }
        let booted = try listDevices().filter { $0.state == "Booted" }
        guard let first = booted.first else { throw SimctlError.noBootedDevice }
        return first.udid
    }

    static func terminate(udid: String, bundleId: String) {
        _ = try? run(["terminate", udid, bundleId])
    }

    /// Launch an app, optionally injecting a dylib via SIMCTL_CHILD_* env. Returns pid.
    static func launch(udid: String, bundleId: String, childEnv: [String: String]) throws -> Int {
        let r = try run(["launch", udid, bundleId], env: childEnv)
        guard r.code == 0 else {
            throw SimctlError.failed("simctl launch failed: \(r.err.isEmpty ? r.out : r.err)")
        }
        // Output is like "<bundleId>: <pid>".
        let digits = r.out.split(whereSeparator: { !$0.isNumber })
        if let last = digits.last, let pid = Int(last) { return pid }
        return -1
    }

    /// Capture a PNG screenshot to a temp file and return its bytes.
    static func screenshotPng(udid: String) throws -> Data {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("reticle-shot-\(UUID().uuidString).png")
        let r = try run(["io", udid, "screenshot", "--type=png", tmp.path])
        guard r.code == 0 else {
            throw SimctlError.failed("simctl io screenshot failed: \(r.err.isEmpty ? r.out : r.err)")
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try Data(contentsOf: tmp)
    }
}
