import Foundation

/// `reticle trace` — read back what was recorded.
///
/// A separate verb from `replay` on purpose. `replay` re-sends a captured
/// network flow or renders a GIF: it acts. `trace` only reads the evidence
/// already on disk, and produces no side effect on the device or the recording.
func cmdTrace(_ args: Args) throws {
    guard let sub = args.positional(1) else {
        throw HelperError(traceUsage)
    }
    switch sub {
    case "log":
        try cmdTraceLog(args)
    default:
        throw HelperError("unknown trace subcommand '\(sub)'\n\(traceUsage)")
    }
}

let traceUsage = """
usage: reticle trace log [<trace-dir>] [--changes <n>] [--json]
       with no <trace-dir>, reads the most recent auto-recorded session
"""

/// Renders a recorded run as a handful of lines per action.
///
/// With no directory it reads the current recording — the live `reticle serve`
/// session if there is one, otherwise the most recent auto session. Reading
/// never rolls or creates a session: asking what happened must not itself
/// count as activity.
private func cmdTraceLog(_ args: Args) throws {
    let root = try traceLogRoot(args)
    let entries = try TraceDigest.entries(at: root)
    let maxChanges = args.option("changes").flatMap { Int($0) } ?? 6

    if JsonEnvelope.enabled(args) {
        try JsonEnvelope.success(TraceDigest.jsonObject(entries, root: root))
        return
    }
    print(TraceDigest.render(entries, root: root, maxChanges: maxChanges))
}

private func traceLogRoot(_ args: Args) throws -> URL {
    if let path = args.positional(2) {
        return URL(fileURLWithPath: path)
    }
    if let info = DaemonDiscovery().readLive() {
        return DaemonDiscovery().traceDirectory(for: info)
    }
    if let dir = AutoSession().lastTraceDirectory() {
        return dir
    }
    throw HelperError(
        "nothing recorded yet — run an `act` command first, or pass a trace directory.\n"
            + "(recording is on by default; RETICLE_NO_AUTO_TRACE=1 turns it off)"
    )
}
