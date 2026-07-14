import Foundation

/// Reticle host command-line entry point.
public enum ReticleCLI {
    public static let version = "0.7.0"
    public static let usage = "usage: reticle <doctor|devices|status|app|act|mutate|debug|ui|mock|serve|version> [--serial <id>] [options]"

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
        case "mock":
            return runMock(args)
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

    private static func runMock(_ args: Args) -> Int32 {
        do {
            try cmdMock(args)
            return 0
        } catch {
            writeError("error: \(error)\n")
            return 1
        }
    }

    private static func runHelperBacked(command: String, args: Args) -> Int32 {
        let serialArg = args.option("serial").flatMap { $0 == "true" ? nil : $0 }
        if shouldUseDaemonHelper(args) {
            let client = DaemonHelperClient(serial: serialArg)
            do {
                try dispatch(command: command, args: args, client: client)
                return 0
            } catch {
                if JsonEnvelope.enabled(args) {
                    JsonEnvelope.error(error)
                } else {
                    writeError("error: \(error)\n")
                }
                return 1
            }
        }

        guard let helper = resolveHelper(args) else {
            writeError("could not find the reticle helper; set RETICLE_HELPER or pass --helper\n")
            return 2
        }

        let client = HelperClient(
            launcher: helper,
            javaHome: ProcessInfo.processInfo.environment["JAVA_HOME"],
            serial: serialArg
        )
        do {
            try client.start()
            try dispatch(command: command, args: args, client: client)
            client.shutdown()
            return 0
        } catch {
            if JsonEnvelope.enabled(args) {
                JsonEnvelope.error(error)
            } else {
                writeError("error: \(error)\n")
            }
            client.shutdown()
            return 1
        }
    }

    private static func dispatch(command: String, args: Args, client: HelperCalling) throws {
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
        case "act": try cmdAct(client, args)
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
    }

    private static func shouldUseDaemonHelper(_ args: Args) -> Bool {
        args.option("use-daemon") == "true"
            || ProcessInfo.processInfo.environment["RETICLE_USE_DAEMON"] == "1"
    }
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
