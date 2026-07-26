import Foundation

/// Reticle host command-line entry point.
public enum ReticleCLI {
    /// The shared release constant; `ReticleVersion.current` is the source.
    public static let version = ReticleVersion.current
    public static let usage = "usage: reticle <doctor|devices|status|app|act|mutate|debug|ui|rule|replay|serve|version> [--serial <id>] [options]"

    /// Runs the Reticle CLI and returns a process exit code.
    public static func run(_ argv: [String]) -> Int32 {
        // A write to a dead helper's stdin pipe (or a closed client socket)
        // must surface as an error at the call site, not deliver SIGPIPE and
        // kill the whole process — fatal for the long-lived serve daemon.
        signal(SIGPIPE, SIG_IGN)
        let args = Args(argv)
        guard let command = args.positional(0) else {
            writeError("\(usage)\n")
            return 2
        }

        switch command {
        case "version", "--version", "-v":
            print("reticle \(version)")
            return 0
        case "help", "--help", "-h":
            print(usage)
            return 0
        case "serve":
            return runServe(args)
        case "helper-daemon":
            // The resident hot-path process; auto-spawned by helper-backed
            // commands, so it stays out of the usage line.
            return runHelperDaemon(args)
        case "rule":
            return runRule(args)
        case "replay":
            return runReplay(args)
        default:
            return runHelperBacked(command: command, args: args)
        }
    }

    private static func runServe(_ args: Args) -> Int32 {
        do {
            let runtime = ServeRuntime(options: ServeOptions(args: args))
            try runtime.run()
            return 0
        } catch {
            writeError("error: \(error)\n")
            return 1
        }
    }

    private static func runRule(_ args: Args) -> Int32 {
        do {
            try cmdRule(args)
            return 0
        } catch {
            writeError("error: \(error)\n")
            return 1
        }
    }

    private static func runReplay(_ args: Args) -> Int32 {
        do {
            try cmdReplay(args)
            return 0
        } catch {
            writeError("error: \(error)\n")
            return 1
        }
    }

    private static func runHelperBacked(command: String, args: Args) -> Int32 {
        let serialArg = args.option("serial").flatMap { $0 == "true" ? nil : $0 }
        do {
            let client = try makeClient(args: args, serial: serialArg)
            defer { client.close() }
            return try dispatch(command: command, args: args, client: client)
        } catch let unavailable as HelperUnavailable {
            // A setup problem, not a failed call: no helper binary means no
            // command could have run. Exits 2 (like a usage error), and stays
            // plain text because there is no RPC result to envelope.
            writeError("\(unavailable.description)\n")
            return 2
        } catch {
            if JsonEnvelope.enabled(args) {
                JsonEnvelope.error(error)
            } else {
                writeError("error: \(error)\n")
            }
            return 1
        }
    }

    /// Picks the backend for a helper-backed command and returns it ready to
    /// call. Four backends, one selection point, in priority order:
    ///
    /// 1. **`--target ios`** — natively in-host (simctl / DYLD / direct HTTP /
    ///    CoreSimulator HID). No Kotlin helper, no daemon broker.
    /// 2. **`--use-daemon`** — forward every call through a running `reticle
    ///    serve` (started with `--helper-broker`).
    /// 3. **the resident per-device helper daemon (default)** — the hot path: the
    ///    first command fork-execs the daemon and waits for its socket (≤5s),
    ///    later commands reuse the warm helper and skip the per-command spawn.
    ///    Opt out with `--no-daemon` / `RETICLE_NO_DAEMON=1`; any bring-up
    ///    failure falls through to (4) rather than failing the command.
    /// 4. **a direct helper spawn** — the always-available fallback.
    private static func makeClient(args: Args, serial: String?) throws -> HelperCalling {
        if (args.option("target") ?? "android") == "ios" {
            return IosHelperClient(serial: serial)
        }
        if shouldUseDaemonHelper(args) {
            return DaemonHelperClient(serial: serial)
        }
        if let client = HelperDaemonLauncher.ensureClient(args: args, serial: serial) {
            return client
        }
        guard let helper = resolveHelper(args) else {
            throw HelperUnavailable("could not find the reticle helper; set RETICLE_HELPER or pass --helper")
        }
        let client = HelperClient(
            launcher: helper,
            javaHome: ProcessInfo.processInfo.environment["JAVA_HOME"],
            serial: serial
        )
        try client.start()
        return client
    }

    /// Returns the process exit code for the command.
    ///
    /// Almost every command is 0-or-throw. `act wait --strict` is the exception:
    /// it projects its three-state outcome onto an exit code for shell/CI
    /// consumers. That projection is opt-in, and never the primary channel — the
    /// outcome is always a field in the result (see `cmdAct`).
    private static func dispatch(command: String, args: Args, client: HelperCalling) throws -> Int32 {
        switch command {
        case "doctor": try cmdDoctor(client, args)
        case "devices": try cmdDevices(client, args)
        case "status": try cmdStatus(client, args)
        case "app":
            switch args.positional(1) {
            case "launch": try cmdLaunch(client, args)
            case "inject": try cmdInject(client, args)
            default: throw HelperError("unknown app subcommand: \(args.positional(1) ?? "<none>")")
            }
        case "inject": try cmdInject(client, args)
        case "launch": try cmdLaunch(client, args)
        case "act": return try cmdAct(client, args)
        case "mutate": try cmdMutate(client, args)
        case "debug": try cmdDebug(client, args)
        case "ui":
            switch args.positional(1) {
            case "report": try cmdUiReport(client, args)
            case "screenshot": try cmdScreenshot(client, args)
            case "tree": try cmdUiRender(client, args, view: "tree")
            case "compact": try cmdUiRender(client, args, view: "compact")
            case "outline": try cmdUiRender(client, args, view: "outline")
            case "node": try cmdUiRender(client, args, view: "node")
            case "regions": try cmdUiRender(client, args, view: "regions")
            default: throw HelperError("unknown ui subcommand: \(args.positional(1) ?? "<none>")")
            }
        default:
            throw HelperError("unknown command: \(command)")
        }
        return 0
    }

    private static func shouldUseDaemonHelper(_ args: Args) -> Bool {
        args.option("use-daemon") == "true"
            || ProcessInfo.processInfo.environment["RETICLE_USE_DAEMON"] == "1"
    }
}

/// No helper backend could be constructed — distinct from a helper that ran and
/// failed, and the only condition that exits 2 instead of 1.
struct HelperUnavailable: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Locates the Kotlin helper executable to spawn.
public func resolveHelper(_ args: Args) -> String? {
    let fm = FileManager.default
    if let explicit = args.option("helper") { return explicit }
    if let env = ProcessInfo.processInfo.environment["RETICLE_HELPER"] { return env }
    let selfDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().path
    let beside = "\(selfDir)/reticle-helper"
    if fm.isExecutableFile(atPath: beside) { return beside }
    let devJvm = "reticle-helper/build/install/reticle-helper/bin/reticle-helper"
    if fm.fileExists(atPath: devJvm) { return devJvm }
    let devNative = "reticle-helper/build/native/reticle-helper"
    if fm.isExecutableFile(atPath: devNative) { return devNative }
    return nil
}

private func writeError(_ message: String) {
    FileHandle.standardError.write(Data(message.utf8))
}
