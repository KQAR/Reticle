import Foundation

/// Reticle host command-line entry point.
public enum ReticleCLI {
    /// The shared release constant; `ReticleVersion.current` is the source.
    public static let version = ReticleVersion.current
    public static let usage = "usage: reticle <doctor|devices|status|app|act|system|mutate|debug|ui|trace|rule|replay|serve|version> [--serial <id>] [options]"

    /// What each command is for, and the subcommands that are otherwise only
    /// discoverable by guessing one and reading the error.
    ///
    /// `--help` used to print the one-line usage and nothing else, and a command
    /// with subcommands answered a missing one with `unknown app subcommand:
    /// <none>` — an error about what you did not type, rather than a list of what
    /// you could.
    public static let help = """
    \(usage)

      doctor                  adb + device readiness (flags offline/unauthorized)
      devices                 list attached devices
      status                  runtime health + identity for one package
      app launch|inject       start a linked app, or load the runtime into a
                              running debuggable one over JDWP
      ui report|compact|tree|outline|node|style|regions|coverage|screenshot
                              capture and project the running UI (`coverage`
                              reports how much of the screen has no selector
                              over it, and why; `outline` and the `--alias`
                              it hands out are Android-only)
      act tap|swipe|drag|type|scroll-to|wheel|wait|batch|activate|hide-keyboard
                              drive real input (`wheel` converges a picker column
                              on a value using the wheel's own reading; it is
                              Android-only)
      system prepare|status|stop|overlay|tree|tap|home|activate|screenshot
                              the out-of-process channel: another process's UI
                              (a permission alert, SpringBoard). iOS real
                              devices only, and it sees one accessibility layer
      mutate                  live-patch an allowlisted view property
      debug logs|logcat       app-authored runtime logs, and the agent's own
      trace log               read back what a recorded run did
      rule / replay           network mocking and request replay
                              (`replay gif|flow`)
      serve                   session daemon + read-only web panel
      version                 print the release

    Every command takes --serial <id> (or ANDROID_SERIAL) and --json.
    iOS: pass --target ios.
    """

    /// Runs the Reticle CLI and returns a process exit code.
    public static func run(_ argv: [String]) async -> Int32 {
        // A write to a dead helper's stdin pipe (or a closed client socket)
        // must surface as an error at the call site, not deliver SIGPIPE and
        // kill the whole process — fatal for the long-lived serve daemon.
        signal(SIGPIPE, SIG_IGN)
        let args = Args(argv)
        guard let command = args.positional(0) else {
            writeError("\(help)\n")
            return 2
        }

        switch command {
        case "version", "--version", "-v":
            print("reticle \(version)")
            return 0
        case "help", "--help", "-h":
            print(help)
            return 0
        case "serve":
            return await runServe(args)
        case "helper-daemon":
            // The resident hot-path process; auto-spawned by helper-backed
            // commands, so it stays out of the usage line.
            return await runHelperDaemon(args)
        case "rule":
            return await runRule(args)
        case "replay":
            return await runReplay(args)
        case "trace":
            return await runTrace(args)
        default:
            return await runHelperBacked(command: command, args: args)
        }
    }

    private static func runServe(_ args: Args) async -> Int32 {
        do {
            let runtime = ServeRuntime(options: try ServeOptions(args: args))
            try await runtime.run()
            return 0
        } catch {
            writeError("error: \(error)\n")
            return 1
        }
    }

    private static func runRule(_ args: Args) async -> Int32 {
        do {
            try await cmdRule(args)
            return 0
        } catch {
            writeError("error: \(error)\n")
            return 1
        }
    }

    private static func runTrace(_ args: Args) async -> Int32 {
        do {
            try await cmdTrace(args)
            return 0
        } catch {
            writeError("error: \(error)\n")
            return 1
        }
    }

    private static func runReplay(_ args: Args) async -> Int32 {
        do {
            try await cmdReplay(args)
            return 0
        } catch {
            writeError("error: \(error)\n")
            return 1
        }
    }

    private static func runHelperBacked(command: String, args: Args) async -> Int32 {
        let serialArg = args.option("serial").flatMap { $0 == "true" ? nil : $0 }
        do {
            // A flag this command does not read used to be dropped, so the command
            // ran as if it had never been passed — `act tap --text "Tak"` reported an
            // empty selector rather than a misplaced flag. Checked before the backend
            // is built, so nothing has touched the device when the answer comes back.
            try CliFlags.validate(args, command: command, subcommand: args.positional(1))
            let backend = try makeBackend(args: args, serial: serialArg)
            defer { backend.close() }
            return try await dispatch(command: command, args: args, backend: backend)
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

    /// Picks the backend for a command and returns it ready to call. Two backends
    /// over four transports, one selection point, in priority order:
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
    private static func makeBackend(args: Args, serial: String?) throws -> HostBackend {
        if (args.option("target") ?? "android") == "ios" {
            // Natively in-host: typed the whole way down, no JSONL anywhere.
            return IosHelperClient(serial: serial)
        }
        // The three Android transports differ only in how the JSONL envelope
        // travels, so one adapter turns any of them into the typed backend.
        if shouldUseDaemonHelper(args) {
            return AndroidBackend(DaemonHelperClient(serial: serial))
        }
        if let client = HelperDaemonLauncher.ensureClient(args: args, serial: serial) {
            return AndroidBackend(client)
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
        return AndroidBackend(client)
    }

    /// Returns the process exit code for the command.
    ///
    /// Almost every command is 0-or-throw. `act wait --strict` is the exception:
    /// it projects its three-state outcome onto an exit code for shell/CI
    /// consumers. That projection is opt-in, and never the primary channel — the
    /// outcome is always a field in the result (see `cmdAct`).
    private static func dispatch(command: String, args: Args, backend: HostBackend) async throws -> Int32 {
        switch command {
        case "doctor": try await cmdDoctor(backend, args)
        case "devices": try await cmdDevices(backend, args)
        case "status": try await cmdStatus(backend, args)
        case "app":
            switch args.positional(1) {
            case "launch": try await cmdLaunch(backend, args)
            case "inject": try await cmdInject(backend, args)
            default:
                // Name what IS available. A missing subcommand answered with
                // "unknown app subcommand: <none>" is an error about what the
                // caller did not type rather than a list of what they could.
                throw HelperError(
                    "usage: reticle app <launch|inject> --package <pkg>"
                        + (args.positional(1).map { "\n  (got '\($0)')" } ?? "")
                )
            }
        case "inject": try await cmdInject(backend, args)
        case "launch": try await cmdLaunch(backend, args)
        // The out-of-process channel. It does NOT go through `backend`: a
        // `HostBackend` is the in-app channel, shared with Android, and the system
        // channel has neither an Android twin nor any method in common with it.
        case "system": try await ReticleSystemCommands.dispatch(args)
        case "act": return try await cmdAct(backend, args)
        case "mutate": try await cmdMutate(backend, args)
        case "debug": try await cmdDebug(backend, args)
        case "ui":
            switch args.positional(1) {
            case "report": try await cmdUiReport(backend, args)
            case "screenshot": try await cmdScreenshot(backend, args)
            case "tree": try await cmdUiRender(backend, args, view: "tree")
            case "compact": try await cmdUiRender(backend, args, view: "compact")
            case "outline": try await cmdUiRender(backend, args, view: "outline")
            case "node": try await cmdUiRender(backend, args, view: "node")
            case "regions": try await cmdUiRender(backend, args, view: "regions")
            case "style": try await cmdUiRender(backend, args, view: "style")
            case "coverage": try await cmdUiRender(backend, args, view: "coverage")
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
