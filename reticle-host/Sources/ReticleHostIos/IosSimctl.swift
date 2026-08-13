import Foundation
import ReticleHostShared

/// Thin wrapper over `xcrun simctl` — the iOS device-control seam (the analogue
/// of Android's `Adb`). Shells out; owns no long-lived state.
public struct Simctl {
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
    ///
    /// `throws` is kept although `Shell` reports a launch failure as `code == -1`
    /// rather than throwing: every caller here already branches on the code, and
    /// changing the signature would churn 28 call sites for nothing.
    @discardableResult
    static func run(_ args: [String], env extraEnv: [String: String] = [:]) throws -> (out: String, err: String, code: Int32) {
        // The concurrent two-pipe drain this used to hand-roll (stderr off-thread
        // so a chatty subcommand filling its ~64KB buffer cannot deadlock a
        // caller blocked on stdout) now lives once, in `Shell`.
        // Bounded: every `simctl` call here answers in seconds, except `boot` /
        // `bootstatus`, which the two-minute ceiling still clears on a cold
        // runtime. A `simctl` that has not answered by then is wedged — a state
        // that used to hang the CLI forever and now fails with which command did it.
        let result = Shell.runSync("/usr/bin/xcrun", ["simctl"] + args,
                                   extraEnvironment: extraEnv, timeout: .seconds(120))
        return (result.out, result.err, result.code)
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

    /// Whether this udid names a SIMULATOR at all. A `--serial` can equally be a
    /// real device's hardware ECID (the id the device path uses everywhere), and
    /// the two must not be confused: a simulator has a HID surface, a device has
    /// none. Unparseable/failed `simctl` answers false — a udid we cannot place in
    /// the simulator list is not one we may assume HID for.
    static func isSimulator(_ udid: String) -> Bool {
        ((try? listDevices()) ?? []).contains { $0.udid == udid }
    }

    /// Whether `bundleId` is installed on this simulator (`simctl listapps`).
    /// Used before dispatching HID at a simulator: keys and touches go to whatever
    /// is on THAT screen, so an app that is not even installed there means the
    /// input would land somewhere else entirely while the agent — reached over
    /// loopback, which a device shares through a USB tunnel — answers healthy.
    static func isAppInstalled(udid: String, bundleId: String) -> Bool {
        guard let r = try? run(["listapps", udid]), r.code == 0 else { return true }
        return r.out.contains("\"\(bundleId)\"") || r.out.contains(bundleId)
    }

    /// Resolve a device: an explicit udid, else the (single) booted simulator.
    /// Public because the daemon needs to attribute captured traffic to a booted
    /// simulator. One of exactly two entry points this target exposes upward.
    public static func resolveUdid(_ serial: String?) throws -> String {
        if let serial, !serial.isEmpty { return serial }
        let booted = try listDevices().filter { $0.state == "Booted" }
        guard let first = booted.first else { throw SimctlError.noBootedDevice }
        return first.udid
    }

    /// Trusts a DER-encoded root certificate in a simulator's keychain, so the
    /// MITM CA is accepted by apps on that device.
    ///
    /// Public, and phrased as a capability rather than as argv: `serve
    /// --proxy-install-ca` used to assemble `["keychain", udid, "add-root-cert", …]`
    /// itself, which put simulator command syntax inside the daemon. The daemon now
    /// states the intent and this target owns the how.
    public static func trustRootCertificate(derPath: String, udid: String) throws {
        let r = try run(["keychain", udid, "add-root-cert", derPath])
        if r.code != 0 {
            throw HelperError("could not trust the MITM CA in simulator \(udid): "
                + (r.err.isEmpty ? r.out : r.err))
        }
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
