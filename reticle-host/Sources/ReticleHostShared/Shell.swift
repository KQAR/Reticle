import Foundation
import Subprocess
import Synchronization
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

    /// How a cancelled or timed-out child is taken down: ask, then insist.
    ///
    /// `xcodebuild` and `devicectl` leave their own children (a simulator clone, a
    /// test runner) behind when killed outright, so they get SIGINT and two
    /// seconds to unwind before SIGTERM; the library always finishes with SIGKILL.
    /// Two seconds because a `devicectl` mid-install needs a moment to stop
    /// cleanly, and nothing here is worth waiting longer for.
    private static var teardown: [TeardownStep] {
        [
            .send(signal: .interrupt, allowedDurationToNextStep: .seconds(2)),
            .send(signal: .terminate, allowedDurationToNextStep: .seconds(1)),
        ]
    }

    /// `Environment.Key` is only literal-expressible, and these keys are built at
    /// run time (`SIMCTL_CHILD_<VAR>`), so they go through the literal initializer.
    private static func environment(_ extra: [String: String]) -> Environment {
        guard !extra.isEmpty else { return .inherit }
        return .inherit.updating(
            Dictionary(uniqueKeysWithValues: extra.map {
                (Environment.Key(stringLiteral: $0.key), Optional($0.value))
            })
        )
    }

    private static func configuration(
        _ executable: String,
        _ arguments: [String],
        _ extraEnvironment: [String: String]
    ) -> Configuration {
        var options = PlatformOptions()
        options.teardownSequence = teardown
        return Configuration(
            executable: .path(FilePath(executable)),
            arguments: Arguments(arguments),
            environment: environment(extraEnvironment),
            platformOptions: options
        )
    }

    /// The async form. Prefer it from anywhere already inside a task.
    ///
    /// - Parameter timeout: how long the child gets before it is torn down. nil
    ///   means "as long as it takes", which is what `waitUntilExit()` gave and
    ///   what a device build legitimately needs. A caller that knows the command
    ///   should be quick passes a bound so a wedged child fails instead of
    ///   hanging the CLI forever.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        extraEnvironment: [String: String] = [:],
        timeout: Duration? = nil
    ) async -> ShellResult {
        do {
            let result = try await withDeadline(timeout, command: executable) {
                try await Subprocess.run(
                    configuration(executable, arguments, extraEnvironment),
                    output: .string(limit: outputLimit),
                    error: .string(limit: outputLimit)
                )
            }
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

    /// Streams the child's output line by line while it runs, and still returns
    /// everything it wrote.
    ///
    /// This is the reason to reach for a real process library rather than collect
    /// a `Pipe` at the end. `system prepare` shells out to `xcodebuild`, which
    /// takes minutes on a cold device build and prints its progress as it goes.
    /// Collected output means that progress arrives all at once, after the wait —
    /// so the command looked hung, and a build that failed 20 seconds in looked
    /// identical to one still working.
    ///
    /// `onLine` sees stdout and stderr interleaved in arrival order, which is what
    /// a person reading a build log wants; the returned result still keeps the two
    /// apart for the callers that classify failures by stream.
    public static func runStreaming(
        _ executable: String,
        _ arguments: [String],
        extraEnvironment: [String: String] = [:],
        timeout: Duration? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> ShellResult {
        let collected = OutputCollector()
        do {
            let result = try await withDeadline(timeout, command: executable) {
                try await Subprocess.run(
                    configuration(executable, arguments, extraEnvironment),
                    input: .none,
                    output: .sequence,
                    error: .sequence
                ) { execution in
                    // Both streams are consumed concurrently for the same reason
                    // the old hand-rolled version drained two pipes on two
                    // threads: whichever one is not being read fills its buffer
                    // and blocks the child.
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask {
                            // A read error ends this stream and nothing else: the
                            // termination status is what decides the result, and a
                            // half-read log is still worth what was read.
                            try? await consume(execution.standardOutput) { line in
                                onLine(line)
                                collected.appendOut(line)
                            }
                        }
                        group.addTask {
                            try? await consume(execution.standardError) { line in
                                onLine(line)
                                collected.appendErr(line)
                            }
                        }
                    }
                }
            }
            let (out, err) = collected.take()
            return ShellResult(out: out, err: err, code: Self.exitCode(result.terminationStatus))
        } catch {
            let (out, err) = collected.take()
            return ShellResult(out: out, err: err.isEmpty ? "\(error)" : err, code: -1)
        }
    }

    private static func consume(
        _ stream: SubprocessOutputSequence,
        _ each: (String) -> Void
    ) async throws {
        for try await line in stream.strings() {
            each(line)
        }
    }

    /// Races the work against a deadline. On expiry the work task is cancelled,
    /// which is what triggers `teardownSequence` on the child — so the timeout
    /// leaves no orphan behind.
    private static func withDeadline<T: Sendable>(
        _ timeout: Duration?,
        command: String,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let timeout else { return try await work() }
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ShellError.timedOut(command: command, after: timeout)
            }
            // The first task to finish decides; cancelling the group tears down
            // whichever of the two is still running (the child, or the timer).
            defer { group.cancelAll() }
            while let next = try await group.next() {
                if let next { return next }
            }
            throw ShellError.timedOut(command: command, after: timeout)
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
        extraEnvironment: [String: String] = [:],
        timeout: Duration? = nil
    ) -> ShellResult {
        let box = OneShot<ShellResult>()
        Task {
            box.resolve(
                await run(executable, arguments,
                          extraEnvironment: extraEnvironment, timeout: timeout))
        }
        // No timeout: this is the same unbounded wait the previous
        // `waitUntilExit()` performed. A child that hangs (a wedged `xcodebuild`)
        // is a real condition the callers already bound at their own level, and a
        // deadline invented here would turn a slow-but-fine device build into a
        // spurious failure.
        return box.wait()
    }

    /// The synchronous streaming form, for `system prepare` — a CLI command whose
    /// whole job is one long build.
    public static func runStreamingSync(
        _ executable: String,
        _ arguments: [String],
        extraEnvironment: [String: String] = [:],
        timeout: Duration? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) -> ShellResult {
        let box = OneShot<ShellResult>()
        Task {
            box.resolve(
                await runStreaming(executable, arguments,
                                   extraEnvironment: extraEnvironment,
                                   timeout: timeout, onLine: onLine))
        }
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

/// Why a child did not answer, for the cases that are not just a non-zero exit.
public enum ShellError: Error, CustomStringConvertible {
    case timedOut(command: String, after: Duration)

    public var description: String {
        switch self {
        case let .timedOut(command, after):
            return "\(command) did not finish within \(after); it was torn down"
        }
    }
}

/// Accumulates the two streams of a streaming run. A class behind a mutex because
/// the two consumers are concurrent tasks.
private final class OutputCollector: Sendable {
    private struct Streams {
        var out: [String] = []
        var err: [String] = []
    }
    private let streams = Mutex(Streams())

    func appendOut(_ line: String) { streams.withLock { $0.out.append(line) } }
    func appendErr(_ line: String) { streams.withLock { $0.err.append(line) } }

    /// Joined with newlines: `strings()` strips the separator it split on, and
    /// every caller treats these as the whole text of a stream.
    func take() -> (String, String) {
        streams.withLock { ($0.out.joined(separator: "\n"), $0.err.joined(separator: "\n")) }
    }
}
