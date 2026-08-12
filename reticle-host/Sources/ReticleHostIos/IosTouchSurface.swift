import Foundation
import ReticleHostShared
import ReticleProtocol

/// The one seam every coordinate gesture goes through, and the reason a real
/// device can have them at all.
///
/// Two surfaces carry the same touch:
///
/// - **`hid`** — a booted simulator's private CoreSimulator digitizer
///   (`CReticleSimHID`), driven from the host.
/// - **`agent`** — a real device, where nothing HID-shaped is reachable from the
///   host, so the touch is synthesized INSIDE the app by the linked agent
///   (`POST /touch`): a `UITouch` in the application's own `UITouchesEvent`,
///   delivered through `-sendEvent:`. That is the same call UIKit makes for a
///   finger, so hit-testing, gesture recognizers and scroll views all behave as
///   they do under one — which is what activation could never do.
///
/// A route that was tried and rejected, recorded so it is not tried again: the
/// digitizer `IOHIDEvent` this repo already builds for the simulator can be
/// constructed in-process on a device (IOKit's constructors resolve, and
/// `UIApplication` answers both `_enqueueHIDEvent:` and `_handleHIDEvent:`), and
/// it is accepted and routed NOWHERE — measured on an iPhone 13 Pro Max / iOS 26
/// across every sender-id, display-integrated and coordinate-space combination.
/// The UIKit path above is what lands.
///
/// Callers state the gesture; which surface carries it is decided once, here.
enum IosTouchSurface {
    case hid(udid: String)
    case agent(bundleId: String)

    var describe: String {
        switch self {
        case .hid: return "hid"
        case .agent: return "agent uikit"
        }
    }

    /// Which surface this run has. A simulator udid means HID (probed, because the
    /// private SimulatorKit layout can be missing); anything else is a real device,
    /// whose surface is the agent's — also probed, since it is private API too.
    static func resolve(simUdid: String?, bundleId: String, gesture: String) throws -> IosTouchSurface {
        if let simUdid, Simctl.isSimulator(simUdid) {
            guard IosInputBackend(udid: simUdid).isAvailable() else {
                throw HelperError(
                    "HID input is unavailable on this simulator: the private SimulatorKit HID path could "
                    + "not be initialized (wrong/missing Xcode SimulatorKit layout)"
                )
            }
            return .hid(udid: simUdid)
        }
        let probe = try agentProbe(bundleId)
        guard probe.available else {
            throw HelperError(
                "\(gesture) needs a touch surface and this device has none: the agent reports "
                + "`\(probe.paths)`. A coordinate gesture on a real device is synthesized inside the app, "
                + "so it needs a linked agent new enough to expose `POST /touch` (and the private UIKit "
                + "surface it uses). `act activate` needs no touch surface."
            )
        }
        return .agent(bundleId: bundleId)
    }

    /// Whether a device could carry a coordinate gesture, without committing to one.
    /// Used where a fallback exists (a selector tap can still be activated).
    static func agentTouchAvailable(_ bundleId: String) -> Bool {
        (try? agentProbe(bundleId).available) ?? false
    }

    private static func agentProbe(_ bundleId: String) throws -> (available: Bool, paths: String) {
        let object: [String: Any]
        do {
            object = try IosAgentHTTP(bundleId: bundleId).getJSONObject(Endpoints.touch)
        } catch {
            throw HelperError("could not ask the agent for a touch surface (is the runtime up?): \(error)")
        }
        return ((object["available"] as? Bool) ?? false, (object["paths"] as? String) ?? "none")
    }

    func tap(x: Double, y: Double, screen: (Double, Double), holdMs: Int? = nil) throws {
        switch self {
        case .hid(let udid):
            try IosInputBackend(udid: udid).tap(x: x, y: y, screen: screen)
        case .agent(let bundleId):
            try post(bundleId, TouchRequest(kind: .tap, from: Point(x: x, y: y), durationMs: holdMs))
        }
    }

    func swipe(from: (Double, Double), to: (Double, Double), screen: (Double, Double), durationMs: Double) throws {
        switch self {
        case .hid(let udid):
            try IosInputBackend(udid: udid).swipe(from: from, to: to, screen: screen, durationMs: durationMs)
        case .agent(let bundleId):
            try post(bundleId, TouchRequest(kind: .drag, from: Point(x: from.0, y: from.1),
                                            to: Point(x: to.0, y: to.1), durationMs: Int(durationMs)))
        }
    }

    /// Which system-channel step the caller needs next, based on where that
    /// channel actually is. "Not installed" and "installed but not connected" need
    /// different commands, so a single generic hint would send half of callers to
    /// the wrong one.
    static func systemChannelHint(_ bundleId: String, udid: String?) -> String {
        let config = IosRunnerConfig(appBundleId: bundleId)
        let next: String
        if let udid {
            // Worth one device round-trip on an error path: the two states need
            // DIFFERENT commands, and a generic hint sends half of callers to the
            // wrong one.
            switch IosRunnerLifecycle(config: config, udid: udid).state() {
            case .notInstalled:
                next = "it is NOT installed yet — run `reticle system prepare --team <id>` first"
            case .installed:
                next = "it is installed but not running — the next `system` command starts it"
            case .connected:
                next = "it is connected and ready"
            }
        } else {
            // No device id is available at this call site (`.agent` carries only a
            // bundle id), so the two states cannot be told apart here. Name BOTH
            // commands rather than guessing — `system status` is what distinguishes
            // them, and sending someone to `prepare` when the channel is merely
            // stopped would waste a full rebuild.
            next = "run `reticle system status --target ios` first — if it says "
                + "notInstalled run `system prepare --team <id>`; if it says installed "
                + "the next `system` command starts it"
        }
        return next
            + ", then `system overlay` to see what is covering the app and "
            + "`system tap --label <text>` to act on it"
    }

    private func post(_ bundleId: String, _ request: TouchRequest) throws {
        let body = try ReticleJSON.encodeWire(request)
        let (data, _) = try IosAgentHTTP(bundleId: bundleId).post(Endpoints.touch, body: body)
        let result = try ReticleJSON.decode(TouchResult.self, from: data)
        guard result.dispatched else {
            // Never a silent no-op: the agent names the surface that was missing, or
            // the fact that no window of this process holds that point (which is what
            // a coordinate aimed at another process's UI looks like from inside).
            // Two very different causes produce this, and a caller who assumes the
            // wrong one wastes the next several minutes:
            //
            //  1. the coordinate is simply wrong — by far the common case;
            //  2. the target genuinely belongs to ANOTHER process (a system alert,
            //     the keyboard's own window, SpringBoard).
            //
            // Deliberately NOT auto-rerouting to the system channel for case 2:
            // a mistyped coordinate would then be dispatched into some other
            // process instead of failing, which is worse than failing.
            throw HelperError(
                "in-process touch failed: \(result.message ?? "unknown"). "
                + "Either that coordinate is not where you think it is, or the target "
                + "belongs to another process (a system alert, the IME, SpringBoard) — "
                + "this path only reaches THIS app's windows. For the second case use "
                + "the system channel: \(IosTouchSurface.systemChannelHint(bundleId, udid: nil))"
            )
        }
    }
}
