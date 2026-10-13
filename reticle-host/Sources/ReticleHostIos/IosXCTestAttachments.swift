import Foundation
import ReticleHostShared

/// What XCTest has left in testmanagerd's container on a real device.
///
/// Since Xcode 15 a UI test is screen-recorded, and the video is deleted only
/// when the test PASSES. A resident runner ends killed, so a runner built before
/// it opted out of the recording left one video per session — measured: 14 GB in
/// 32 files on one phone. They sit outside every app sandbox, survive a reboot
/// and show up only as "System Data", so nothing but this check points at them.
public enum IosXCTestAttachments {

    /// Above this, `doctor` warns. A session leaves a few MB per minute, so 1 GB
    /// is hours of runner time — past "a few short runs", well before a full disk.
    public static let warnBytes: Int64 = 1_000_000_000

    public struct Finding: Sendable, Equatable {
        public var udid: String
        public var name: String
        /// Bytes per attachments directory, keyed by its container-relative path.
        /// iOS 26 keeps it at the container root, older releases under `tmp/`.
        public var bytesByRoot: [String: Int64]
        /// Set when the device could not be read; the sizes are then empty.
        public var error: String?

        public var totalBytes: Int64 { bytesByRoot.values.reduce(0, +) }
    }

    static let roots = ["Attachments", "tmp/Attachments"]
    static let container = ["--domain-type", "appDataContainer",
                            "--domain-identifier", "com.apple.testmanagerd"]

    /// Every reachable physical iOS device, or only `serial` when given. A device
    /// that cannot be read becomes a finding with `error`, never a thrown error:
    /// this is advice inside `doctor`, and must not take `doctor` down with it.
    public static func scan(serial: String?) async -> [Finding] {
        guard let list = await devicectlJSON(["list", "devices"]) else { return [] }
        var findings: [Finding] = []
        for (udid, name) in physicalDevices(fromList: list)
        where serial == nil || serial == udid {
            guard let files = await devicectlJSON(["device", "info", "files", "--device", udid]
                                                  + container + ["--username", "mobile"]) else {
                findings.append(Finding(udid: udid, name: name, bytesByRoot: [:],
                                        error: "could not list testmanagerd's container"))
                continue
            }
            findings.append(Finding(udid: udid, name: name, bytesByRoot: bytesByRoot(fromFiles: files)))
        }
        return findings
    }

    /// `devicectl list devices` JSON -> (hardware udid, name) of physical iOS
    /// devices that are not `unavailable`. Virtual devices are skipped: devicectl
    /// file calls time out against them.
    static func physicalDevices(fromList data: Data) -> [(String, String)] {
        let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let devices = (result?["result"] as? [String: Any])?["devices"] as? [[String: Any]] ?? []
        return devices.compactMap { d in
            let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
            let conn = d["connectionProperties"] as? [String: Any] ?? [:]
            guard hw["platform"] as? String == "iOS", hw["reality"] as? String == "physical",
                  conn["tunnelState"] as? String != "unavailable",
                  let udid = hw["udid"] as? String else { return nil }
            let name = (d["deviceProperties"] as? [String: Any])?["name"] as? String ?? udid
            return (udid, name)
        }
    }

    /// `devicectl device info files` JSON -> file bytes under each attachments root.
    static func bytesByRoot(fromFiles data: Data) -> [String: Int64] {
        let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let files = (result?["result"] as? [String: Any])?["files"] as? [[String: Any]] ?? []
        var out: [String: Int64] = [:]
        for f in files {
            guard let path = f["relativePath"] as? String,
                  (f["resources"] as? [String: Any])?["isDirectory"] as? Bool != true,
                  let root = roots.first(where: { path.hasPrefix($0 + "/") }) else { continue }
            let size = ((f["metadata"] as? [String: Any])?["size"] as? NSNumber)?.int64Value ?? 0
            out[root, default: 0] += size
        }
        return out
    }

    /// The `doctor` lines for one finding: nothing under the threshold, otherwise
    /// the size and the command that clears it.
    public static func advice(_ f: Finding) -> [String] {
        if let error = f.error {
            return ["  \(f.name) (\(f.udid)): xctest attachments unknown — \(error)"]
        }
        guard f.totalBytes > warnBytes else { return [] }
        let gb = String(format: "%.1f", Double(f.totalBytes) / 1e9)
        var lines = ["  warning: \(f.name) (\(f.udid)) holds \(gb) GB of leftover XCTest "
                     + "screen recordings (shown as System Data). Stop any running UI test, then:"]
        for root in roots where (f.bytesByRoot[root] ?? 0) > 0 {
            lines.append("    mkdir -p /tmp/reticle-empty && xcrun devicectl device copy to --device \(f.udid) "
                         + container.joined(separator: " ")
                         + " --user mobile --source /tmp/reticle-empty --destination \(root)"
                         + " --remove-existing-content true")
        }
        lines.append("    (a closing CoreDeviceError 7000 is expected; the files are gone — re-run doctor to confirm)")
        return lines
    }

    private static func devicectlJSON(_ args: [String]) async -> Data? {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("reticle-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: path) }
        let r = await Shell.run("/usr/bin/xcrun", ["devicectl"] + args + ["--json-output", path.path],
                                timeout: .seconds(60))
        guard r.code == 0 else { return nil }
        return try? Data(contentsOf: path)
    }
}
