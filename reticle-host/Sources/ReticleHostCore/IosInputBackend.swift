import Foundation
import CReticleSimHID

/// Input synthesis for the iOS simulator, isolated behind this seam (the analogue
/// of Android's `InputBackend`). It calls the private CoreSimulator HID bridge in
/// `CReticleSimHID`. This path is **simulator-only** and **fragile across Xcode
/// versions** by nature; every failure surfaces a descriptive error rather than a
/// silent no-op. On a real device this backend is unavailable (no HID surface).
struct IosInputBackend {
    let udid: String

    enum InputError: Error, CustomStringConvertible {
        case hid(String)
        var description: String {
            switch self {
            case .hid(let m): return "iOS HID input: \(m)"
            }
        }
    }

    private func errorBuffer() -> [CChar] { [CChar](repeating: 0, count: 512) }

    private func message(_ buf: [CChar]) -> String {
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// True if a HID client can be obtained for this simulator right now.
    func isAvailable() -> Bool {
        var buf = errorBuffer()
        return reticle_sim_hid_available(udid, &buf, buf.count) == 0
    }

    func tap(x: Double, y: Double, screen: (w: Double, h: Double)) throws {
        var buf = errorBuffer()
        let rc = reticle_sim_hid_tap(udid, x, y, screen.w, screen.h, &buf, buf.count)
        if rc != 0 { throw InputError.hid(message(buf)) }
    }

    func swipe(from: (Double, Double), to: (Double, Double), screen: (w: Double, h: Double), durationMs: Double) throws {
        var buf = errorBuffer()
        let rc = reticle_sim_hid_swipe(udid, from.0, from.1, to.0, to.1, screen.w, screen.h, durationMs, &buf, buf.count)
        if rc != 0 { throw InputError.hid(message(buf)) }
    }

    func type(_ text: String) throws {
        var buf = errorBuffer()
        let rc = reticle_sim_hid_type(udid, text, &buf, buf.count)
        if rc != 0 { throw InputError.hid(message(buf)) }
    }

    /// Cmd+V — paste the clipboard (staged by the agent) into the focused field.
    func paste() throws {
        var buf = errorBuffer()
        let rc = reticle_sim_hid_paste(udid, &buf, buf.count)
        if rc != 0 { throw InputError.hid(message(buf)) }
    }
}

enum IosText {
    /// Whether the HID keyboard can emit every character — printable ASCII,
    /// 0x20..0x7E. Mirrors Android's `InputBackend.isAsciiTypeable`; anything
    /// outside (CJK, emoji, accented Latin, and control chars like newline)
    /// routes through the clipboard + paste path instead of being silently
    /// dropped by the keyboard.
    static func isHidTypeable(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }
}
