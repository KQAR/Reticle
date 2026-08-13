import Foundation
import Testing
@testable import ReticleHostCore

/// The command surface, against itself.
///
/// AGENTS.md names `ReticleCLI.usage` the source for what the CLI exposes, but the
/// list is spelled three times: the usage/help text (what a user is told), the two
/// `switch`es in `ReticleCLI` (what actually runs), and `CliFlags.tableForSuggestions`
/// (what the "you meant this command" hint walks). Nothing checked them against each
/// other, and they had drifted: the whole `system` family shipped without appearing in
/// help, `trace` advertised a `replay` subcommand it never had, and `debug` was listed
/// as taking no subcommands while shipping `logs` and `logcat`.
///
/// The dispatch side is read out of the source rather than enumerated by hand — a
/// fourth hand-written list is a fourth thing to drift. Swift cannot enumerate a
/// switch's cases, and the parse is the same device `HelperMethodContractTests` uses
/// on the RPC markdown.
@Suite("the CLI command surface agrees with itself")
struct CommandSurfaceTests {

    /// Commands that dispatch but are deliberately absent from usage, with the reason.
    /// An entry here is a decision; an unexplained absence is the drift this suite catches.
    private static let undocumentedOnPurpose: Set<String> = [
        // Auto-spawned by helper-backed commands, never typed by a user.
        "helper-daemon",
        // Pre-`app` aliases for `app inject` / `app launch`, kept working for
        // scripts written against them and deliberately not advertised again.
        "inject", "launch",
        // `help` and its flag spellings: the command that PRINTS the usage line does
        // not need to appear in it. Same for `version`'s flag forms.
        "help", "--help", "-h", "--version", "-v",
    ]

    private func source(_ name: String) throws -> String {
        // <repo>/reticle-host/Tests/ReticleHostCoreTests/<this file>
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent("reticle-host/Sources/ReticleHostCore/CLI/\(name)"),
            encoding: .utf8
        )
    }

    /// Every `case "x", "y":` label in ReticleCLI's two top-level switches.
    private func dispatchedCommands() throws -> Set<String> {
        let text = try source("ReticleCLI.swift")
        var found: Set<String> = []
        // Only the two top-level switches are at this indentation; the nested
        // subcommand switches (`args.positional(1)`) sit deeper.
        let pattern = try NSRegularExpression(pattern: #"^        case ((?:"[^"]+"(?:, )?)+):"#, options: [.anchorsMatchLines])
        let ns = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let labels = ns.substring(with: match.range(at: 1))
            for raw in labels.components(separatedBy: ", ") {
                found.insert(raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
            }
        }
        return found
    }

    /// The commands named between the angle brackets of the usage line.
    private func usageCommands() -> Set<String> {
        guard let open = ReticleCLI.usage.firstIndex(of: "<"),
              let close = ReticleCLI.usage.firstIndex(of: ">") else { return [] }
        let inner = ReticleCLI.usage[ReticleCLI.usage.index(after: open)..<close]
        return Set(inner.components(separatedBy: "|"))
    }

    @Test func theUsageLineParsesAtAll() {
        // A guard on the two parses below: an empty set would make every other
        // assertion in this suite vacuously true.
        #expect(usageCommands().count > 5)
    }

    @Test func everyDispatchedCommandIsDocumented() throws {
        let dispatched = try dispatchedCommands()
        #expect(dispatched.count > 10, "parsed too few cases out of ReticleCLI — did the switches move?")
        let undocumented = dispatched
            .subtracting(usageCommands())
            .subtracting(Self.undocumentedOnPurpose)
            .sorted()
        let why = "these commands run but ReticleCLI.usage does not name them: \(undocumented). "
            + "AGENTS.md makes usage the source for the command surface — add them there, "
            + "or add them to `undocumentedOnPurpose` with the reason."
        #expect(undocumented.isEmpty, Comment(rawValue: why))
    }

    @Test func everyDocumentedCommandActuallyRuns() throws {
        let dispatched = try dispatchedCommands()
        let phantom = usageCommands().subtracting(dispatched).sorted()
        #expect(phantom.isEmpty, "usage names commands nothing dispatches: \(phantom)")
    }

    @Test func helpExplainsEveryCommandUsageNames() {
        // `usage` is one line of names; `help` is the part a user reads to find out
        // what each one is for. A name in the first and not the second is a command
        // discoverable only by guessing.
        let body = ReticleCLI.help.replacingOccurrences(of: ReticleCLI.usage, with: "")
        for command in usageCommands().sorted() {
            #expect(body.contains(command), "`help` never explains '\(command)'")
        }
    }

    @Test func theFlagSuggestionTableNamesOnlyRealCommands() throws {
        let dispatched = try dispatchedCommands()
        for command in CliFlags.tableForSuggestions.keys.sorted() {
            #expect(dispatched.contains(command),
                    "tableForSuggestions lists '\(command)', which nothing dispatches")
            #expect(usageCommands().contains(command),
                    "tableForSuggestions lists '\(command)', which usage does not name")
        }
    }

    /// The subcommand lists that CAN be checked against the source: `ui`, `act` and
    /// `app` dispatch theirs inside ReticleCLI, so a name added to one switch and not
    /// to the table fails here. (`system`, `rule`, `replay` and `trace` dispatch in
    /// their own files and validate no flags, so they are not in the table at all.)
    @Test func theFlagSuggestionTableMatchesTheSubcommandSwitches() throws {
        let text = try source("ReticleCLI.swift")
        for family in ["ui", "act", "app"] {
            guard let listed = CliFlags.tableForSuggestions[family], listed != [""] else { continue }
            for subcommand in listed {
                let why = "tableForSuggestions['\(family)'] lists '\(subcommand)', which the "
                    + "subcommand switch does not handle"
                #expect(text.contains("case \"\(subcommand)\"") || family == "act", Comment(rawValue: why))
            }
        }
        // `act` gestures are dispatched inside `cmdAct`/the backends rather than by a
        // switch here, so they are pinned by the help text instead — which is what a
        // user reads to learn they exist.
        for gesture in CliFlags.tableForSuggestions["act"] ?? [] {
            #expect(ReticleCLI.help.contains(gesture), "help never mentions `act \(gesture)`")
        }
    }
}
