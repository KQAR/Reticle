import Foundation

/// Which `--flags` each command accepts, so a flag it does not accept is reported
/// as such instead of being dropped.
///
/// Why this exists: `Args` parses every `--x` into a dictionary and each command
/// reads the keys it knows, so a flag nobody reads is silently ignored and the
/// command runs as if it had never been passed. Measured while driving a real
/// flow: `act tap --package <pkg> --text "Tak"` answered
///
///     could not resolve selector '<empty>' to a point. Use one of: …
///
/// which reads as "your selector was empty" — the caller sees no connection to the
/// flag they typed, and `--text` IS a selector-ish flag on `act type` and `act
/// wait`, so "unknown" was never obvious. The real answer is two facts: `--text`
/// is not accepted by `act tap`, and it IS accepted by `act type` / `act wait`.
///
/// Scope is deliberate. Only the commands listed here are validated; a command
/// with no table (`rule`, `replay`, `trace`, `serve`) is left alone rather than
/// guessed at, because a false "unknown option" REJECTS a call that used to work —
/// worse than the papercut it fixes. Anything global (`--serial`, `--json`, …) is
/// accepted everywhere.
enum CliFlags {

    /// Accepted by every command: transport and output selection, not behaviour.
    static let global: Set<String> = [
        "serial", "json", "target", "helper", "use-daemon", "no-daemon", "port", "socket",
    ]

    /// Selector flags shared by the acting gestures.
    private static let selectors: Set<String> = [
        "test-id", "resource-id", "css", "ref", "point", "label", "region", "alias",
    ]

    /// What every gesture (except `wait` / `batch`, which have their own shapes)
    /// accepts on top of a selector: settle policy, verification, tracing.
    private static let actCommon: Set<String> = [
        "package", "no-toast-probe", "settle", "no-settle", "settle-timeout",
        "verify", "verify-timeout", "trace-output", "trace-delay",
    ]

    /// The table. `nil` from `accepted` means "not validated", not "accepts nothing".
    static func accepted(command: String, subcommand: String?) -> Set<String>? {
        switch command {
        case "doctor", "devices":
            return []
        case "status":
            return ["package"]
        case "app", "launch", "inject":
            let sub = command == "app" ? subcommand : command
            switch sub {
            case "launch": return ["package"]
            case "inject": return ["package", "payload-dex", "restart-under-debugger"]
            default: return nil
            }
        case "mutate":
            return ["package", "property", "value", "test-id", "resource-id", "ref", "region"]
        case "debug":
            return ["package"]
        case "ui":
            switch subcommand {
            case "report": return ["package", "output"]
            case "screenshot": return ["package", "output"]
            case "tree":
                return renderFlags.union(["semantics"])
            case "compact", "outline", "node", "regions", "style", "coverage":
                return renderFlags
            default: return nil
            }
        case "act":
            return actFlags(subcommand)
        default:
            return nil
        }
    }

    private static let renderFlags: Set<String> = [
        "live", "package", "depth", "window", "test-id", "resource-id", "css", "ref",
    ]

    private static func actFlags(_ gesture: String?) -> Set<String>? {
        switch gesture {
        case "tap", "activate", "hide-keyboard":
            return actCommon.union(selectors)
        case "type":
            return actCommon.union(selectors).union(["text", "submit", "clear", "type-delay"])
        case "swipe", "drag":
            return actCommon.union(selectors).union(["from", "to", "duration"])
        case "scroll-to":
            return actCommon.union(selectors).union(["container", "direction", "max-swipes"])
        case "wait":
            return [
                "package", "test-id", "resource-id", "css", "ref", "label", "alias", "point",
                "for", "gone", "idle", "text", "timeout", "quiet-for", "strict",
            ]
        case "batch":
            return ["package", "file", "trace-output", "trace-delay"]
        default:
            return nil
        }
    }

    /// Throws when the invocation carries a flag this command does not read.
    ///
    /// The message states the two facts a caller needs: that this flag is not
    /// accepted HERE, and — when it is a real Reticle flag — which commands do
    /// accept it, since that is almost always the mistake (right flag, wrong
    /// gesture).
    static func validate(_ args: Args, command: String, subcommand: String?) throws {
        guard let accepted = accepted(command: command, subcommand: subcommand) else { return }
        let allowed = accepted.union(global)
        let unknown = args.optionNames.filter { !allowed.contains($0) }
        guard !unknown.isEmpty else { return }
        let where_ = ([command] + (subcommand.map { [$0] } ?? [])).joined(separator: " ")
        let listed = unknown.sorted().map { "--\($0)" }.joined(separator: ", ")
        var message = "unknown option\(unknown.count == 1 ? "" : "s") \(listed) for `\(where_)`."
        for flag in unknown.sorted() {
            let elsewhere = commandsAccepting(flag)
            if !elsewhere.isEmpty {
                message += " `--\(flag)` is accepted by: \(elsewhere.joined(separator: ", "))."
            }
        }
        message += " `\(where_)` accepts: " + accepted.sorted().map { "--\($0)" }.joined(separator: ", ")
            + " (plus the global " + global.sorted().map { "--\($0)" }.joined(separator: ", ") + ")."
        throw HelperError(message)
    }

    /// Every validated command that accepts `flag`, so a misplaced flag can be
    /// pointed at the place it belongs.
    private static func commandsAccepting(_ flag: String) -> [String] {
        var hits: [String] = []
        for (command, subcommands) in tableForSuggestions {
            let matching = subcommands.filter { subcommand in
                accepted(command: command, subcommand: subcommand.isEmpty ? nil : subcommand)?
                    .contains(flag) == true
            }
            if matching.isEmpty { continue }
            // A flag most of a family takes (`--package`, `--live`) would otherwise
            // print nine `ui …` lines and bury the one fact that matters.
            if matching.count > 2, matching.count == subcommands.count {
                hits.append("\(command) *")
            } else {
                hits += matching.map { $0.isEmpty ? command : "\(command) \($0)" }
            }
        }
        return hits.sorted()
    }

    /// The command/subcommand pairs `commandsAccepting` walks. Listed rather than
    /// derived because `accepted` is a switch, not a dictionary — and a switch is
    /// what keeps each command's flags readable next to the code that reads them.
    private static let tableForSuggestions: [String: [String]] = [
        "status": [""],
        "app": ["launch", "inject"],
        "mutate": [""],
        "debug": [""],
        "ui": ["report", "screenshot", "tree", "compact", "outline", "node", "regions", "style", "coverage"],
        "act": ["tap", "type", "swipe", "drag", "scroll-to", "wait", "batch", "activate", "hide-keyboard"],
    ]
}
