import Foundation
import Darwin

/// On-disk record that `reticle serve` set a device-wide proxy on an Android
/// device. The graceful stop path clears it, but a daemon that dies without
/// running restore (`SIGKILL`, a crash) would otherwise strand the device on a
/// dead proxy — its `http_proxy` still points at a port nothing listens on, so
/// the device loses network until manually cleared. This marker lets the next
/// `serve` detect that stranding and reconcile it.
///
/// Keyed by the target serial (so distinct devices don't clobber each other) and
/// stamped with the owning pid, so reconciliation only fires for a daemon that is
/// no longer alive — never for a peer daemon that legitimately still owns it.
struct DeviceProxyState: Codable {
    let pid: Int32
    let serial: String?
    let proxyPort: Int
    let previous: String?

    private static func directory() -> URL {
        DaemonDiscovery.reticleHome().appendingPathComponent("device-proxy", isDirectory: true)
    }

    private static func fileURL(serial: String?) -> URL {
        let key = (serial?.isEmpty == false) ? serial! : "default"
        let safe = String(key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        return directory().appendingPathComponent("\(safe).json")
    }

    /// Records that this daemon (pid) set the device proxy.
    func write() {
        let url = Self.fileURL(serial: serial)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    /// Removes the marker for `serial` (called after a successful restore).
    static func clear(serial: String?) {
        try? FileManager.default.removeItem(at: fileURL(serial: serial))
    }

    /// A marker left by a daemon that is no longer alive (so its proxy was never
    /// restored), or nil when there is none or a live daemon still owns it.
    static func readStale(serial: String?) -> DeviceProxyState? {
        let url = fileURL(serial: serial)
        guard
            let data = try? Data(contentsOf: url),
            let state = try? JSONDecoder().decode(DeviceProxyState.self, from: data)
        else { return nil }
        // A live owner means this is not stranded — leave it alone.
        if state.pid > 0 && kill(state.pid, 0) == 0 { return nil }
        return state
    }
}
