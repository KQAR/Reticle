import Foundation
import ReticleHostShared
import ReticleProtocol

/// The system channel driven from the Mac, with nothing on the device.
///
/// A CoreDevice tunnel gives the host what the runner had to be a UI test for:
/// a HID connection backboardd routes into ANY process (touch, Home), and the
/// device's own cross-process accessibility tree (remoteAX). Each call spawns
/// `reticle-device` (Rust, over the MIT `idevice` crate) for one action. So
/// there is no install, no signing team, no resident process and no
/// automation-session lock. The runner stays behind `--via runner`.
///
/// What the device reports is NOT what XCUITest reports, and the results say so:
/// - The tree holds only what is in front. With a system modal up, SpringBoard's
///   tree holds the modal's texts and buttons and nothing else. There is no alert
///   element (measured on iOS 27.0.1). So `overlay` means "SpringBoard is in
///   front and it is not the home screen".
/// - There is no hit test, so `isHittable` is always false and is named in
///   `unreadable`.
public struct IosHostSystemChannel: Sendable {

    public static let channelName = "system-host"
    static let springboard = "com.apple.springboard"

    public let udid: String
    let tool: String

    public static func make(udid: String) async throws -> IosHostSystemChannel {
        if await Simctl.isSimulator(udid) {
            throw HelperError(
                "the system channel is a REAL-DEVICE capability and \(udid) is a simulator. "
                + "On a simulator `act tap` already reaches a system alert and `ui screenshot` shows it"
            )
        }
        guard let tool = resolveDeviceTool() else {
            throw HelperError(
                "reticle-device is missing: it ships beside reticle-host in a release; from source build it with "
                + "`cargo build --release --manifest-path reticle-device/Cargo.toml`, or set RETICLE_DEVICE. "
                + "`--via runner` uses the XCUITest runner instead"
            )
        }
        return IosHostSystemChannel(udid: udid, tool: tool)
    }

    // MARK: - Status

    public func status() -> String {
        guard let probe = try? call(["probe"]),
              let services = probe["services"] as? [String: Bool] else {
            return "system: unavailable channel=host device=\(udid)\n"
                + "  no CoreDevice tunnel: is the device attached over USB, unlocked, trusted and in developer mode?"
        }
        let missing = services.filter { !$0.value }.keys.sorted()
        guard missing.isEmpty else {
            return "system: unavailable channel=host device=\(udid) missing=[\(missing.joined(separator: ", "))]\n"
                + "  the developer disk image provides these: attach the device to Xcode once to mount it"
        }
        return "system: ready channel=host device=\(udid) (nothing to install; each command opens its own tunnel)"
    }

    // MARK: - Reading

    public func overlay() throws -> SystemObservation {
        try readTree().overlay()
    }

    public func tree(target: SystemReadTarget) throws -> SystemObservation {
        let tree = try readTree()
        switch target {
        case .topmostOverlay: return tree.overlay()
        case .home: return try tree.front(named: Self.springboard)
        case .app(let bundle): return try tree.front(named: bundle)
        }
    }

    // MARK: - Driving

    public func tap(label: String) throws -> SystemActionResult {
        let before = try readTree()
        let via = "label:\(label)"
        guard before.frontBundle == Self.springboard else {
            return SystemActionResult(
                dispatched: false, targetProcess: Self.springboard, via: via,
                refusal: "no system layer is in front (\(before.frontBundle ?? "an unidentified app") is); "
                    + "a label inside the app is `act tap`'s job"
            )
        }
        let buttons = before.frontButtons()
        guard let hit = buttons.first(where: { $0.label == label }), let frame = hit.frame else {
            return SystemActionResult(
                dispatched: false, targetProcess: Self.springboard, via: via,
                refusal: "no control with that label is on the system layer right now",
                available: buttons.compactMap(\.label)
            )
        }
        return try tap(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2, before: before, via: via)
    }

    public func tap(x: Double, y: Double) throws -> SystemActionResult {
        try tap(x: x, y: y, before: try readTree(), via: "point:\(Int(x)),\(Int(y))")
    }

    private func tap(x: Double, y: Double, before: HostAXTree, via: String) throws -> SystemActionResult {
        guard let screen = before.screenSize else {
            throw HelperError("the device reported no screen frame; cannot place a coordinate")
        }
        guard let (nx, ny) = HostAXTree.normalize(x: x, y: y, screen: screen) else {
            return SystemActionResult(
                dispatched: false, targetProcess: before.frontBundle, via: via,
                refusal: "coordinate is outside the \(Int(screen.width))x\(Int(screen.height)) screen"
            )
        }
        _ = try call(["tap", String(nx), String(ny)])
        let after = try readTree()
        return SystemActionResult(
            dispatched: true,
            // Compared, not assumed: a tap that moved nothing is a real outcome.
            changed: before.signature != after.signature,
            targetProcess: before.frontBundle, via: via
        )
    }

    public func home() throws -> SystemActionResult {
        _ = try call(["home"])
        // The caller checks the side effect; claiming it here would be a verdict.
        return SystemActionResult(dispatched: true, changed: nil, targetProcess: Self.springboard, via: "home")
    }

    /// Bring an app forward WITHOUT restarting it (instruments launch with
    /// KillExisting=false), then report what is in front.
    public func activate(bundleId: String) throws -> SystemActionResult {
        _ = try call(["launch", bundleId])
        let after = try readTree()
        // With a system modal over it, the app can be in front and still not be
        // what the tree shows. Then nothing can be claimed either way.
        let changed: Bool? = after.overlayIsUp ? nil : after.frontBundle == bundleId
        return SystemActionResult(dispatched: true, changed: changed, targetProcess: bundleId, via: "activate")
    }

    public func screenshot() throws -> ScreenshotResult {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("reticle-device-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try call(["screenshot", path])
        let png = try Data(contentsOf: URL(fileURLWithPath: path))
        return ScreenshotResult(pngBase64: png.base64EncodedString(), via: "system-host:display", degraded: [])
    }

    // MARK: - Transport

    func readTree() throws -> HostAXTree {
        try HostAXTree.decode(try call(["tree"]))
    }

    /// One `reticle-device` invocation; its single JSON line, or its error.
    func call(_ args: [String]) throws -> [String: Any] {
        // The tool bounds itself at 60 s; this only catches a tool that never exits.
        let r = Shell.runSync(tool, [udid] + args, timeout: .seconds(90))
        let line = r.out.split(separator: "\n").last.map(String.init) ?? ""
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
            throw HelperError("reticle-device \(args.first ?? "") failed (exit \(r.code)): "
                + (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard obj["ok"] as? Bool == true else {
            throw HelperError("reticle-device \(args.first ?? ""): \(obj["error"] as? String ?? "failed")")
        }
        return obj
    }
}

/// Where `reticle-device` lives: `$RETICLE_DEVICE`, beside this host (a release),
/// or the cargo output of a source checkout.
func resolveDeviceTool() -> String? {
    let fm = FileManager.default
    if let env = ProcessInfo.processInfo.environment["RETICLE_DEVICE"] { return env }
    let selfURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let selfDir = selfURL.deletingLastPathComponent()
    let candidates = [
        selfDir.appendingPathComponent("reticle-device").path,
        // reticle-host/.build/<config>/ReticleHost -> repo root is three up.
        selfDir.appendingPathComponent("../../../reticle-device/target/release/reticle-device").standardized.path,
        fm.currentDirectoryPath + "/reticle-device/target/release/reticle-device",
    ]
    return candidates.first { fm.isExecutableFile(atPath: $0) }
}

/// One `reticle-device tree` answer, and the rules for reading it.
struct HostAXTree {
    struct App { let id: String; let pid: Int?; let bundleId: String? }
    struct Element {
        var children: [String] = []
        var elementType: Int?
        var label: String?
        var value: String?
        var placeholder: String?
        var identifier: String?
        var frame: Rect?
        var enabled: Bool = true
    }

    var apps: [App]
    var nodes: [String: Element]

    static func decode(_ obj: [String: Any]) throws -> HostAXTree {
        let apps = (obj["apps"] as? [[String: Any]] ?? []).compactMap { a -> App? in
            guard let id = a["id"] as? String else { return nil }
            return App(id: id, pid: a["pid"] as? Int, bundleId: a["bundleId"] as? String)
        }
        var nodes: [String: Element] = [:]
        for (id, raw) in obj["nodes"] as? [String: [String: Any]] ?? [:] {
            var e = Element()
            e.children = raw["children"] as? [String] ?? []
            e.elementType = raw["elementType"] as? Int
            e.label = (raw["label"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            e.value = raw["value"] as? String
            e.placeholder = raw["placeholder"] as? String
            e.identifier = raw["identifier"] as? String
            if let f = raw["frame"] as? [Double], f.count == 4 {
                e.frame = Rect(x: f[0], y: f[1], width: f[2], height: f[3])
            }
            e.enabled = raw["enabled"] as? Bool ?? true
            nodes[id] = e
        }
        guard apps.contains(where: { nodes[$0.id] != nil }) else {
            throw HelperError("the device's accessibility tree named no application")
        }
        return HostAXTree(apps: apps, nodes: nodes)
    }

    /// XCUIElementType.icon: what a home screen is made of.
    static let iconType = 44
    static let buttonType = 9

    var front: App? { apps.first { nodes[$0.id] != nil } }
    var frontBundle: String? { front?.bundleId }
    var screenSize: (width: Double, height: Double)? {
        guard let f = front.flatMap({ nodes[$0.id]?.frame }), f.width > 0, f.height > 0 else { return nil }
        return (f.x + f.width, f.y + f.height)
    }

    /// Every element under the front application, depth first.
    func frontElements() -> [(id: String, element: Element)] {
        guard let root = front?.id else { return [] }
        var out: [(String, Element)] = []
        var seen = Set<String>()
        func walk(_ id: String) {
            guard seen.insert(id).inserted, let e = nodes[id] else { return }
            out.append((id, e))
            e.children.forEach(walk)
        }
        walk(root)
        return out
    }

    func frontButtons() -> [Element] {
        frontElements().map(\.element).filter { $0.elementType == Self.buttonType }
    }

    /// SpringBoard in front and NOT showing the home screen: a system modal (or
    /// Control Center, or Notification Center) is covering whatever app ran.
    var overlayIsUp: Bool {
        frontBundle == IosHostSystemChannel.springboard
            && !frontElements().contains { $0.element.elementType == Self.iconType }
    }

    /// What changed between two reads, coarsely: who is in front and which labels
    /// it shows.
    var signature: String {
        (frontBundle ?? "?") + "|" + frontElements().compactMap(\.element.label).joined(separator: "\u{1f}")
    }

    func overlay() -> SystemObservation {
        guard overlayIsUp else {
            return SystemObservation(overlayPresent: false, sourceChannel: IosHostSystemChannel.channelName,
                                     targetProcess: IosHostSystemChannel.springboard)
        }
        return observation()
    }

    /// The front application's tree, when it is the one asked for. This channel
    /// reads only what is on screen, so a target that is not in front is refused
    /// with what IS there rather than answered with an empty tree.
    func front(named bundle: String) throws -> SystemObservation {
        guard frontBundle == bundle else {
            throw HelperError(
                "\(bundle) is not in front (\(frontBundle ?? "an unidentified app") is). The host channel "
                + "reads only what is on screen — bring it forward first (`system home` / `system activate`)"
            )
        }
        return observation()
    }

    private func observation() -> SystemObservation {
        let elements = frontElements()
        var refs: [String: String] = [:]
        for (i, e) in elements.enumerated() { refs[e.id] = "s\(i + 1)" }
        var gaps = SystemNode.channelGaps
        gaps["isHittable"] = "system-host-has-no-hit-test"
        var nodes: [String: SystemNode] = [:]
        var parent: [String: String] = [:]
        for (id, e) in elements {
            for c in e.children { if let r = refs[c], parent[r] == nil { parent[r] = refs[id] } }
        }
        for (id, e) in elements {
            guard let ref = refs[id] else { continue }
            nodes[ref] = SystemNode(
                ref: ref,
                parentRef: parent[ref],
                children: e.children.compactMap { refs[$0] },
                role: SystemRole.fromElementType(e.elementType ?? 0),
                label: e.label,
                value: e.value,
                placeholder: e.placeholder,
                testId: e.identifier,
                frame: e.frame,
                isEnabled: e.enabled,
                isHittable: false,
                unreadable: gaps
            )
        }
        return SystemObservation(
            rootRef: elements.first.flatMap { refs[$0.id] },
            nodes: nodes,
            overlayPresent: true,
            sourceChannel: IosHostSystemChannel.channelName,
            targetProcess: frontBundle
        )
    }

    /// A point on the screen in the HID digitizer's 0...65535 space, or nil when
    /// it is off screen.
    static func normalize(x: Double, y: Double, screen: (width: Double, height: Double)) -> (Int, Int)? {
        guard x >= 0, y >= 0, x <= screen.width, y <= screen.height else { return nil }
        return (Int((x / screen.width * 65535).rounded()), Int((y / screen.height * 65535).rounded()))
    }
}
