import Foundation

/// The agent guide, compiled into this binary, and the stubs that point agents at it.
///
/// The guide used to ship as a Claude Code / Cursor plugin, a second artifact with
/// its own update cycle: the binary and the skill describing it could be at two
/// different versions, and upgrading one did not upgrade the other. Now the text
/// lives in `SkillGuide/` (embedded with `.embedInCode`), `reticle skill show`
/// prints it, and what an agent's skills directory holds is a few hundred bytes
/// saying "run `reticle skill show`". Upgrading the binary IS upgrading the skill.
enum ReticleSkill {
    /// Bump only when the stub's own text changes shape. `status` compares the
    /// whole file anyway (the description comes from the guide and changes with
    /// it); this number is for a reader of the file.
    static let stubVersion = "1"

    static let guide = String(decoding: PackageResources.SKILL_md, as: UTF8.self)

    /// `.embedInCode` flattens file names into identifiers and offers no way to
    /// enumerate them, so the table is written out. `SkillGuideTests` fails when a
    /// file under `SkillGuide/references/` is missing from it.
    static let topics: [String: [UInt8]] = [
        "action-traces": PackageResources.action_traces_md,
        "daemon-and-panel": PackageResources.daemon_and_panel_md,
        "flows-and-waiting": PackageResources.flows_and_waiting_md,
        "ios-agent-setup": PackageResources.ios_agent_setup_md,
        "ios-system-channel": PackageResources.ios_system_channel_md,
        "keyboard": PackageResources.keyboard_md,
        "network-rules": PackageResources.network_rules_md,
        "webview-dom-and-style": PackageResources.webview_dom_and_style_md,
    ]

    /// The guide's YAML frontmatter (between the two `---` lines) and its body.
    static var frontmatter: (yaml: String, body: String) {
        let parts = guide.components(separatedBy: "\n---\n")
        let yaml = parts[0].hasPrefix("---\n") ? String(parts[0].dropFirst(4)) : parts[0]
        return (yaml, parts.dropFirst().joined(separator: "\n---\n"))
    }

    /// The file `setup` writes. Name and description are the guide's own, so an
    /// agent decides to load it exactly as it would have decided to load the guide.
    static var stub: String {
        """
        ---
        \(frontmatter.yaml)
        metadata:
          reticle-stub: "\(stubVersion)"
        ---
        <!-- Installed by "reticle skill setup". Remove it with "reticle skill remove". -->

        Run `reticle skill show` and follow the guide it prints. The guide comes from
        the installed Reticle CLI, so it describes the commands available in that
        version. It points at deeper topics; print one with `reticle skill show <topic>`.

        If `reticle` is not on PATH, it is not installed (macOS 15+ arm64):
        `curl -fsSL https://raw.githubusercontent.com/KQAR/Reticle/main/install.sh | bash`.
        If `reticle skill show` fails, the installed CLI predates the guide: run
        `reticle update`.

        """
    }

    /// One skills directory and the agents that read it. Several agents share
    /// `~/.agents/skills`, so it is written once for all of them.
    struct Target {
        let agents: String
        let path: String          // relative to $HOME
        let markers: [String]     // any of these existing means an agent is installed

        var directory: URL { home.appendingPathComponent(path) }
        var file: URL { directory.appendingPathComponent("SKILL.md") }
        var detected: Bool {
            markers.contains { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) }
        }
    }

    /// Cursor is in the shared row on evidence, not by guess: its agent (CLI
    /// 2026.02.27) always loads `~/.cursor/skills` and `~/.agents/skills`, and also
    /// `~/.claude/skills` while third-party extensibility is on (the default). A
    /// third directory for it would only add a copy it already reads.
    static let targets = [
        Target(agents: "Claude Code", path: ".claude/skills/reticle", markers: [".claude"]),
        Target(agents: "Codex, OpenCode, Pi, Cursor", path: ".agents/skills/reticle",
               markers: [".codex", ".config/opencode", ".pi", ".cursor", ".agents"]),
    ]

    enum State: String { case current, outdated, missing, foreign }

    static func state(_ target: Target) -> State {
        guard let text = try? String(contentsOf: target.file, encoding: .utf8) else { return .missing }
        if text == stub { return .current }
        // A SKILL.md without our marker is someone else's file (a hand copy of the
        // old plugin skill, say). Never overwritten or deleted.
        return text.contains("reticle-stub:") ? .outdated : .foreign
    }

    static func write(_ target: Target) throws {
        try FileManager.default.createDirectory(at: target.directory, withIntermediateDirectories: true)
        try Data(stub.utf8).write(to: target.file, options: .atomic)
    }

    /// Rewrites every installed stub that no longer matches this binary. Run by
    /// `update` (through the NEW binary) so an upgrade carries its stub along.
    static func refreshInstalled() -> [String] {
        targets.compactMap { target in
            guard state(target) == .outdated else { return nil }
            do {
                try write(target)
                return "refreshed  \(tilde(target.directory))"
            } catch {
                return "could not refresh \(tilde(target.directory)): \(error)"
            }
        }
    }
}

private var home: URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
}

func tilde(_ url: URL) -> String {
    let path = url.path
    return path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
}

let skillUsage = "usage: reticle skill <show [<topic>]|setup|status|remove>"

func cmdSkill(_ args: Args) throws {
    switch args.positional(1) {
    case "show":
        guard let topic = args.positional(2) else {
            print(ReticleSkill.frontmatter.body.drop(while: \.isNewline), terminator: "")
            return
        }
        guard let bytes = ReticleSkill.topics[topic] else {
            throw HelperError("unknown topic '\(topic)'; topics: \(ReticleSkill.topics.keys.sorted().joined(separator: ", "))")
        }
        print(String(decoding: bytes, as: UTF8.self), terminator: "")
    case "setup":
        if args.flag("installed-only") {
            // Hidden: what `update` runs through the new binary.
            ReticleSkill.refreshInstalled().forEach { print($0) }
            return
        }
        let found = ReticleSkill.targets.filter(\.detected)
        if found.isEmpty {
            print("no supported agent found (looked for ~/.claude, ~/.codex, ~/.config/opencode, ~/.pi, ~/.cursor, ~/.agents)")
            return
        }
        for target in found {
            let where_ = tilde(target.directory)
            switch ReticleSkill.state(target) {
            case .current: print("up to date  \(where_)  (\(target.agents))")
            case .foreign: print("skipped     \(where_)  (a SKILL.md not written by reticle is there; remove it to install)")
            case .missing, .outdated:
                try ReticleSkill.write(target)
                print("wrote       \(where_)  (\(target.agents))")
            }
        }
    case "status":
        for target in ReticleSkill.targets {
            let found = target.detected ? "found" : "not found"
            print("\(target.agents) (\(found))")
            print("  skill  \(ReticleSkill.state(target).rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(tilde(target.directory))")
        }
    case "remove":
        for target in ReticleSkill.targets {
            let state = ReticleSkill.state(target)
            guard state == .current || state == .outdated else { continue }
            try FileManager.default.removeItem(at: target.file)
            // Leave the directory if something else was put in it.
            if (try? FileManager.default.contentsOfDirectory(atPath: target.directory.path))?.isEmpty == true {
                try FileManager.default.removeItem(at: target.directory)
            }
            print("removed     \(tilde(target.directory))")
        }
    default:
        throw HelperError(skillUsage + (args.positional(1).map { "\n  (got '\($0)')" } ?? ""))
    }
}
