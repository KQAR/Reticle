import Foundation
import ReticleHostIos
import ReticleHostShared
import ReticleProtocol

/// The `system` command family: the out-of-process channel, kept in its own
/// namespace so its results can never be mistaken for the app's own.
///
/// `ui` and `act` read and drive the app FROM INSIDE it. `system` reads and drives
/// what is OUTSIDE it — a permission alert, SpringBoard — and sees far less of
/// whatever it touches. Separate commands mean a caller always knows which of the
/// two answered, without having to inspect a source field.
enum ReticleSystemCommands {

    static let usage = """
    usage: reticle system <prepare|status|stop|overlay|tree|tap|home|activate|screenshot> [options]

      prepare --team <id>   build, sign and install the runner on the device (once)
      status                where the channel is: notInstalled / installed / connected
      stop                  shut the runner down and release the device
      overlay               read what is covering the app right now
      tree [what]           read a named target: home | <bundle-id> (default: topmost)
      tap --label <text>    tap a labelled control on the system layer
      tap --point <x,y>     tap an absolute screen coordinate
      screenshot [--out f]  display-level PNG, including whatever covers the app
      home                  press Home (sends the app under test to the background)
      activate --package <bundle>
                            bring an app back to the front WITHOUT restarting it

    options:
      --serial <udid>       target device (defaults to the only attached one)
      --package <bundle>    the app under test, used for port-collision checks
    """

    static func dispatch(_ args: Args) throws {
        guard (args.option("target") ?? "android") == "ios" else {
            throw HelperError(
                "the system channel is iOS-only; pass --target ios"
            )
        }

        let sub = args.positional(1)
        switch sub {
        case "prepare": try prepare(args)
        case "status": try status(args)
        case "stop": try stop(args)
        case "overlay": try overlay(args)
        case "tree": try tree(args)
        case "tap": try tap(args)
        case "screenshot": try screenshot(args)
        case "home": try home(args)
        case "activate": try activate(args)
        default:
            // Name what IS available rather than only what the caller typed.
            throw HelperError(usage + (sub.map { "\n  (got '\($0)')" } ?? ""))
        }
    }

    // MARK: - Commands

    static func prepare(_ args: Args) throws {
        guard let team = args.option("team") else {
            throw HelperError(
                "system prepare needs a signing team: --team <id>. A device build must be "
                + "signed with YOUR team; usable teams on this machine: "
                + describeTeams()
            )
        }
        let backend = try makeBackend(args)
        let outcome = try backend.prepare(team: team, runnerProjectPath: runnerProjectPath())

        var line = "system prepared: state=\(outcome.state.rawValue) device=\(outcome.deviceId)"
        if outcome.replacedExisting {
            // Never swap something out from under the caller silently.
            line += " replaced=previous-install"
        }
        print(line)
        print("  next: any `system` command starts it; no rebuild happens per session")
    }

    static func status(_ args: Args) throws {
        let backend = try makeBackend(args)
        let s = backend.status()
        print(s.describe)
        if let advice = s.advice { print("  \(advice)") }
    }

    static func stop(_ args: Args) throws {
        let backend = try makeBackend(args)
        let outcome = backend.stop()
        // Stopping something that was already stopped is success: it is the state
        // the caller asked for.
        print(outcome.hadLiveInstance
              ? "system stopped: state=\(outcome.state.rawValue)"
              : "system stopped: nothing was running (state=\(outcome.state.rawValue))")
    }

    // MARK: - Reading

    static func overlay(_ args: Args) throws {
        let backend = try makeBackend(args)
        render(try backend.overlay(), args: args)
    }

    static func tree(_ args: Args) throws {
        // Positional, NOT `--target`: that flag already means the platform
        // (ios/android) everywhere else in this CLI, and reusing it here made
        // `system tree --target home` parse as "platform=home" and get refused as
        // non-iOS. One flag, one meaning.
        let raw = args.positional(2) ?? "topmost"
        let target: SystemReadTarget
        switch raw {
        case "topmost": target = .topmostOverlay
        case "home": target = .home
        default: target = .app(bundleId: raw)
        }
        let backend = try makeBackend(args)
        render(try backend.tree(target: target), args: args)
    }

    /// Print an observation.
    ///
    /// The first line always states the CHANNEL and the process, because these
    /// nodes are not the app's own tree and must never be read as if they were.
    static func render(_ obs: SystemObservation, args: Args) {
        var head = "channel=\(obs.sourceChannel)"
        if let p = obs.targetProcess { head += " process=\(p)" }
        if obs.runnerRestarted {
            // Starting or restarting the runner took the foreground from whatever
            // was there — observable interference the caller would otherwise
            // attribute to the app under test.
            head += " warning:runner-started-mid-command"
        }
        print(head)

        guard obs.overlayPresent else {
            // The positive answer, spelled out. An empty tree here would make the
            // caller guess between "nothing is covering it" and "the read failed".
            print("overlay: none — nothing is covering the app right now")
            return
        }

        if let t = obs.truncation {
            print("truncated: returned=\(t.returned) limit=\(t.limit) reason=\(t.reason)")
        }

        guard let rootRef = obs.rootRef else { return }
        printNode(rootRef, in: obs, depth: 0)

        // State the channel's blind spots once per read, rather than repeating a
        // dozen `unreadable` keys on every node.
        let gaps = obs.nodes[rootRef]?.unreadable.keys.sorted() ?? []
        if !gaps.isEmpty {
            print("unreadable by this channel: \(gaps.joined(separator: ", "))")
            print("  (read those through `ui`/`act` on the app's own tree instead)")
        }
    }

    private static func printNode(_ ref: String, in obs: SystemObservation, depth: Int) {
        guard let node = obs.nodes[ref] else { return }
        let pad = String(repeating: "  ", count: depth)
        var line = "\(pad)#\(node.ref) \(node.role.wireName)"
        if let id = node.testId { line += " id=\(id)" }
        if let label = node.label { line += " \"\(label)\"" }
        if let value = node.value, value != node.label { line += " value=\(value)" }
        if let f = node.frame {
            line += " @[\(Int(f.x)),\(Int(f.y)) \(Int(f.width))x\(Int(f.height))]"
        }
        if !node.isEnabled { line += " disabled" }
        if node.isHittable { line += " hittable" }
        print(line)
        for child in node.children { printNode(child, in: obs, depth: depth + 1) }
    }

    static func screenshot(_ args: Args) throws {
        let backend = try makeBackend(args)
        let shot = try backend.screenshot()
        let path = args.option("out") ?? "system-screenshot.png"
        guard let data = Data(base64Encoded: shot.pngBase64) else {
            throw HelperError("the runner returned an unreadable image")
        }
        try data.write(to: URL(fileURLWithPath: path))

        // Always state the framing. An in-process screenshot on a device renders
        // only this app's own layers, so the two pictures answer different
        // questions and a caller must be able to tell which one they are holding.
        var line = "wrote \(path) (\(data.count) bytes) via=\(shot.via ?? "unknown")"
        line += " framing=display-level (includes other processes)"
        if !shot.degraded.isEmpty { line += " degraded=[\(shot.degraded.joined(separator: ", "))]" }
        print(line)
    }

    // MARK: - Driving

    static func tap(_ args: Args) throws {
        let backend = try makeBackend(args)
        if let label = args.option("label") {
            print(try backend.act { try $0.tap(label: label) }.describe)
            return
        }
        guard let point = args.option("point") else {
            throw HelperError("system tap needs --label <text> or --point <x,y>")
        }
        let parts = point.split(separator: ",")
        guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) else {
            throw HelperError("--point wants two numbers: --point 120,480")
        }
        print(try backend.act { try $0.tap(x: x, y: y) }.describe)
    }

    static func home(_ args: Args) throws {
        let backend = try makeBackend(args)
        print(try backend.act { try $0.home() }.describe)
    }

    static func activate(_ args: Args) throws {
        guard let bundleId = args.option("package") ?? args.option("bundle-id") else {
            throw HelperError("system activate needs --package <bundle-id>")
        }
        let backend = try makeBackend(args)
        print(try backend.act { try $0.activate(bundleId: bundleId) }.describe)
    }

    // MARK: - Wiring

    static func makeBackend(_ args: Args) throws -> IosSystemBackend {
        guard let udid = args.option("serial") ?? soleAttachedDevice() else {
            throw HelperError(
                "could not tell which device to use: pass --serial <udid> "
                + "(`idevice_id -l` lists attached devices)"
            )
        }
        let appBundleId = args.option("package") ?? args.option("bundle-id") ?? ""
        return try IosSystemBackend.make(udid: udid, appBundleId: appBundleId)
    }

    /// The single attached device, when there is exactly one. Ambiguity is refused
    /// rather than guessed: driving the wrong phone is worse than being asked.
    static func soleAttachedDevice() -> String? {
        // `idevice_id` is not always installed; a missing binary comes back as a
        // launch failure (code -1), which falls out of the count check below as
        // "not exactly one device" — the same answer it always gave.
        let result = Shell.runSync("/usr/bin/env", ["idevice_id", "-l"])
        let ids = result.out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return ids.count == 1 ? ids[0] : nil
    }

    static func describeTeams() -> String {
        let teams = IosRunnerLifecycle.usableTeams().sorted()
        return teams.isEmpty ? "(none found on this machine)" : teams.joined(separator: ", ")
    }

    /// Where the runner project lives, relative to the installed CLI or the repo.
    static func runnerProjectPath() -> String {
        if let override = ProcessInfo.processInfo.environment["RETICLE_RUNNER_PROJECT"] {
            return override
        }
        return "reticle-runner-ios/ReticleRunner.xcodeproj"
    }
}
