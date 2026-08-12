import Foundation
import Subprocess
import System

/// What a finished child process left behind.
public struct ShellResult: Sendable {
    public let out: String
    public let err: String
    /// The exit status, or -1 when the child was killed by a signal or could not
    /// be launched at all. Callers compare against 0, and the failure text is in
    /// `err` either way, so one number covers both.
    public let code: Int32

    public init(out: String, err: String, code: Int32) {
        self.out = out
        self.err = err
        self.code = code
    }
}

/// Runs a one-shot child process and collects both streams.
///
/// The host shells out constantly — `simctl`, `devicectl`, `xcodebuild`,
/// `iproxy`, `pkill`, `idevice_id` — and before this, four separate call sites
/// each hand-rolled the same thing: `Process` + two `Pipe`s + a background drain
/// of one stream while the caller blocks on the other. That dance is not
/// optional. Reading stdout to EOF and stderr afterwards deadlocks the moment a
/// chatty child fills stderr's ~64KB pipe buffer, and `xcodebuild` is exactly
/// that kind of child. One of the four sites had the bug latent.
///
/// `swift-subprocess` owns that concern, so this type is a thin adapter: it maps
/// the library's result onto the `(out, err, code)` triple the call sites already
/// speak, and it adds the synchronous entry point they need.
///
/// NOT for every child. `run` owns the process's whole lifetime, which is right
/// for a command that answers and exits, and wrong for the three children this
/// host deliberately outlives: the detached helper daemon, the resident
/// `xcodebuild test-without-building` runner, and the `iproxy` tunnel. Those keep
/// using `Process` — see their call sites.
public enum Shell {
    /// Output cap per stream. Generous: `xcodebuild` build logs are the largest
    /// thing read here and land well under this, while a runaway child is still
    /// bounded rather than able to exhaust memory.
    public static let outputLimit = 16 * 1024 * 1024

    /// The async form. Prefer it from anywhere already inside a task.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        extraEnvironment: [String: String] = [:]
    ) async -> ShellResult {
        // `Environment.Key` is only literal-expressible, and these keys are built
        // at run time (`SIMCTL_CHILD_<VAR>`), so they go through the literal
        // initializer explicitly.
        let environment: Environment = extraEnvironment.isEmpty
            ? .inherit
            : .inherit.updating(
                Dictionary(uniqueKeysWithValues: extraEnvironment.map {
                    (Environment.Key(stringLiteral: $0.key), Optional($0.value))
                })
            )
        do {
            let result = try await Subprocess.run(
                .path(FilePath(executable)),
                arguments: Arguments(arguments),
                environment: environment,
                output: .string(limit: outputLimit),
                error: .string(limit: outputLimit)
            )
            return ShellResult(
                out: result.standardOutput,
                err: result.standardError,
                code: Self.exitCode(result.terminationStatus)
            )
        } catch {
            // A launch failure (executable missing, not executable) is reported
            // the same way a non-zero exit is: callers of these commands branch
            // on `code` and surface `err`, and "xcrun is not there" and "xcrun
            // failed" need the same handling from them.
            return ShellResult(out: "", err: "\(error)", code: -1)
        }
    }

    /// The synchronous form, for the CLI command paths — which are synchronous
    /// from `main` down through `HostBackend`, and are not being made async to
    /// suit a process runner.
    ///
    /// This blocks the calling thread while the work runs on the cooperative
    /// pool. That is acceptable here and nowhere near a server hot path: a CLI
    /// invocation exists to run this one command, and `reticle serve`'s request
    /// threads are its own, not the pool's.
    public static func runSync(
        _ executable: String,
        _ arguments: [String],
        extraEnvironment: [String: String] = [:]
    ) -> ShellResult {
        let box = OneShot<ShellResult>()
        Task {
            box.resolve(await run(executable, arguments, extraEnvironment: extraEnvironment))
        }
        // No timeout: this is the same unbounded wait the previous
        // `waitUntilExit()` performed. A child that hangs (a wedged `xcodebuild`)
        // is a real condition the callers already bound at their own level, and a
        // deadline invented here would turn a slow-but-fine device build into a
        // spurious failure.
        return box.wait()
    }

    private static func exitCode(_ status: TerminationStatus) -> Int32 {
        switch status {
        case .exited(let code): return code
        // Killed by a signal. -1 rather than the signal number: every caller
        // treats this as "did not succeed", and a positive signal number could
        // be mistaken for an exit code.
        case .signaled: return -1
        }
    }
}
