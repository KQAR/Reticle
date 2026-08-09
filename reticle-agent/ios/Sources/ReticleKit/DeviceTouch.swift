import Foundation
import ReticleProtocol
#if canImport(UIKit)
import UIKit
import CReticleDeviceTouch

/// In-process touch synthesis for a REAL DEVICE — the gap `act activate` cannot
/// close, because activation fires an action while a touch goes through
/// hit-testing, gesture recognizers and scroll views. It is the same digitizer
/// `IOHIDEvent` the simulator bridge builds (`CReticleSimHID`), handed to THIS
/// process's UIKit instead of to a `SimDevice` client, so what it drives is a real
/// touch: a self-drawn agreement row, a seat map's sub-element, a scroll view.
///
/// Capability-probed like the simulator bridge: every path is private API, so a
/// missing symbol or selector is reported by name rather than silently no-op'ing
/// — the failure that matters most is an agent believing it tapped.
///
/// Boundary, stated once here: this reaches THIS PROCESS's windows only. Another
/// process's UI — a system alert, the remote keyboard's own window, SpringBoard —
/// is not reachable, and no in-process path can change that.
enum DeviceTouch {

    /// What resolved in this process, and whether a dispatch path exists at all.
    static func probe() -> (available: Bool, report: String) {
        var buffer = [CChar](repeating: 0, count: 1024)
        let rc = reticle_device_touch_probe(&buffer, buffer.count)
        return (rc == 0, string(from: buffer))
    }

    /// Which view a touch at this point would reach. Reported alongside every
    /// dispatched touch: an action that changed nothing is a different finding
    /// depending on whether it landed on the intended control or on an overlay.
    @MainActor
    static func hitView(at point: CGPoint) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let rc = reticle_device_touch_hit_view(Double(point.x), Double(point.y), &buffer, buffer.count)
        return rc == 0 ? string(from: buffer) : nil
    }

    enum TouchError: Error, CustomStringConvertible {
        case unavailable(String)
        var description: String {
            switch self {
            case .unavailable(let reason): return reason
            }
        }
    }

    /// One event, on the main thread. `phase`: 0=down, 1=move, 2=up. Points are in
    /// screen space, which is what every rect Reticle reports is measured in.
    @MainActor
    private static func send(_ point: CGPoint, phase: Int32) throws {
        var err = [CChar](repeating: 0, count: 256)
        let rc = reticle_device_touch_send(Double(point.x), Double(point.y), phase, &err, err.count)
        if rc != 0 { throw TouchError.unavailable(string(from: err)) }
    }

    private static func string(from buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A tap: down, hold briefly, up. The hold matters — a down/up in the same run
    /// loop turn is seen by some gesture recognizers as a cancelled touch.
    static func tap(at point: CGPoint, holdMs: Int = 60) throws {
        try MainThread.sync { try send(point, phase: 0) }
        Thread.sleep(forTimeInterval: Double(holdMs) / 1000.0)
        try MainThread.sync { try send(point, phase: 2) }
    }

    /// A press held for `durationMs` — a long press, whose recognizer needs the
    /// touch to stay down across several run loop turns.
    static func longPress(at point: CGPoint, durationMs: Int) throws {
        try tap(at: point, holdMs: max(durationMs, 1))
    }

    /// A drag from `from` to `to`, stepped so momentum and scroll views see a real
    /// movement rather than a teleport. `durationMs` sets the pace: a fling and a
    /// careful drag differ only in how long the same path takes.
    static func drag(from: CGPoint, to: CGPoint, durationMs: Int, steps: Int = 20) throws {
        let count = max(steps, 2)
        let stepDelay = Double(max(durationMs, 1)) / Double(count) / 1000.0
        try MainThread.sync { try send(from, phase: 0) }
        for step in 1...count {
            let t = Double(step) / Double(count)
            let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            Thread.sleep(forTimeInterval: stepDelay)
            try MainThread.sync { try send(point, phase: 1) }
        }
        try MainThread.sync { try send(to, phase: 2) }
    }
}
#endif
