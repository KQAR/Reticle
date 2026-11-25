import Foundation

/// Installing and switching releases: `~/.reticle/versions/<v>` holds each
/// unpacked release, `~/.reticle/current` links the active one, and
/// `~/.local/bin/reticle` links `current/bin/reticle-host`.
///
/// This is the only place the layout is written down. `install.sh` downloads the
/// first zip and hands the unpacked directory to `reticle update --from <dir>`, so
/// the first install and every later switch run the same code.
enum ReticleInstall {
    static let asset = "reticle-macos-arm64.zip"

    private static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var home: URL { URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory()) }
    static var root: URL { home.appendingPathComponent(".reticle") }
    static var versions: URL { root.appendingPathComponent("versions") }
    static var current: URL { root.appendingPathComponent("current") }
    static var binLink: URL { home.appendingPathComponent(".local/bin/reticle") }
    static var repo: String { env["RETICLE_REPO"] ?? "KQAR/Reticle" }
    /// `<base>/v<version>/<asset>`. Overridable so an install can be exercised
    /// against a local directory of zips (`file://…`) before a release exists.
    static var releasesURL: String { env["RETICLE_RELEASES_URL"] ?? "https://github.com/\(repo)/releases/download" }

    static func normalized(_ version: String) -> String {
        version.hasPrefix("v") ? String(version.dropFirst()) : version
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let parse = { (v: String) in v.split(separator: ".").map { Int($0) ?? 0 } }
        return parse(b).lexicographicallyPrecedes(parse(a))
    }

    /// The active version, read from the `current` link.
    static var activeVersion: String? {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path))
            .map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    static func latestVersion() async throws -> String {
        let r = await Shell.run("/usr/bin/curl", ["-fsSL", "-m", "10", "https://api.github.com/repos/\(repo)/releases/latest"])
        guard r.code == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
              let tag = json["tag_name"] as? String else {
            throw HelperError("could not look up the latest release of \(repo) (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines))); pass --to <version>")
        }
        return normalized(tag)
    }

    /// Downloads, verifies and unpacks one release into a scratch directory, and
    /// returns the unpacked `reticle/` directory.
    static func download(_ version: String) async throws -> URL {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("reticle-update-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        let base = "\(releasesURL)/v\(version)"
        let zip = scratch.appendingPathComponent(asset).path
        let sums = scratch.appendingPathComponent("SHA256SUMS").path
        for (url, out) in [("\(base)/\(asset)", zip), ("\(base)/SHA256SUMS", sums)] {
            let r = await Shell.run("/usr/bin/curl", ["-fsSL", "-o", out, url])
            guard r.code == 0 else { throw HelperError("download failed: \(url)\n\(r.err)") }
        }
        // A release always publishes SHA256SUMS, so a missing line is a refusal,
        // not a skipped check.
        let expected = (try String(contentsOfFile: sums, encoding: .utf8))
            .split(separator: "\n")
            .first { $0.hasSuffix(" \(asset)") }?
            .split(separator: " ").first.map(String.init)
        let actual = await Shell.run("/usr/bin/shasum", ["-a", "256", zip]).out.split(separator: " ").first.map(String.init)
        guard let expected, expected == actual else {
            throw HelperError("checksum mismatch for \(asset) v\(version) (expected \(expected ?? "<none>"), got \(actual ?? "<none>")); refusing it")
        }
        let unzip = await Shell.run("/usr/bin/unzip", ["-q", "-o", zip, "-d", scratch.path])
        guard unzip.code == 0 else { throw HelperError("unpack failed: \(unzip.err)") }
        return scratch.appendingPathComponent("reticle")
    }

    /// Makes the unpacked release at `dir` the active one and returns what it did.
    static func activate(_ dir: URL) async throws -> [String] {
        let fm = FileManager.default
        let host = dir.appendingPathComponent("bin/reticle-host")
        guard fm.isExecutableFile(atPath: host.path) else {
            throw HelperError("\(dir.path) is not an unpacked release (no bin/reticle-host)")
        }
        // The release names itself; nothing upstream of this has to agree on it.
        let reported = await Shell.run(host.path, ["version"], extraEnvironment: ["RETICLE_NO_UPDATE_CHECK": "1"]).out
        guard let version = reported.split(separator: " ").last?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else {
            throw HelperError("\(host.path) did not report a version")
        }
        var log: [String] = []
        let dest = versions.appendingPathComponent(version)
        if dir.standardizedFileURL.resolvingSymlinksInPath() != dest.standardizedFileURL.resolvingSymlinksInPath() {
            try fm.createDirectory(at: versions, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: dir, to: dest)
        }

        let previous = activeVersion
        // Swap `current` atomically: a command started mid-switch sees the old
        // release or the new one, never no link at all.
        let staged = root.appendingPathComponent("current.new")
        try? fm.removeItem(at: staged)
        try fm.createSymbolicLink(atPath: staged.path, withDestinationPath: "versions/\(version)")
        guard rename(staged.path, current.path) == 0 else {
            throw HelperError("could not switch \(current.path): \(String(cString: strerror(errno)))")
        }
        log.append(previous == nil || previous == version
            ? "reticle \(version) active (\(tilde(dest)))"
            : "reticle \(previous!) -> \(version) (\(tilde(dest)))")

        // The PATH entry. A real file there is somebody else's; leave it.
        let linkTarget = current.appendingPathComponent("bin/reticle-host").path
        let attrs = try? fm.attributesOfItem(atPath: binLink.path)
        if let type = attrs?[.type] as? FileAttributeType, type != .typeSymbolicLink {
            log.append("left \(tilde(binLink)) alone: it is not a link this installer made. Point it at \(linkTarget).")
        } else if (try? fm.destinationOfSymbolicLink(atPath: binLink.path)) != linkTarget {
            try fm.createDirectory(at: binLink.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: binLink)
            try fm.createSymbolicLink(atPath: binLink.path, withDestinationPath: linkTarget)
            log.append("linked \(tilde(binLink)) -> \(tilde(URL(fileURLWithPath: linkTarget)))")
        }
        let pathDirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        if !pathDirs.contains(binLink.deletingLastPathComponent().path) {
            log.append("~/.local/bin is not on PATH; add this line to your shell profile:")
            log.append("  export PATH=\"$HOME/.local/bin:$PATH\"")
        }

        // Keep the active release and the one it replaced (a one-command rollback
        // with `update --to`); anything older goes.
        let keep: Set<String> = [version, previous].compactMap { $0 }.reduce(into: []) { $0.insert($1) }
        for name in (try? fm.contentsOfDirectory(atPath: versions.path)) ?? [] where !keep.contains(name) {
            try? fm.removeItem(at: versions.appendingPathComponent(name))
            log.append("removed old release \(name)")
        }

        // Installed skill stubs follow the binary. Asked of the NEW release, since
        // it is the one whose stub text counts; a release older than the guide does
        // not know the command, and then there is nothing to refresh.
        let refresh = await Shell.run(dest.appendingPathComponent("bin/reticle-host").path,
                                      ["skill", "setup", "--installed-only"])
        if refresh.code == 0 {
            log += refresh.out.split(separator: "\n").map(String.init)
        }
        return log
    }

    /// "a newer release exists" for `version`, checked at most once a day
    /// (`RETICLE_NO_UPDATE_CHECK=1` skips it). Failures are cached too, so an
    /// offline machine pays the 2s timeout once a day, not on every call.
    static func newerReleaseNotice() async -> String? {
        if env["RETICLE_NO_UPDATE_CHECK"] == "1" { return nil }
        let stamp = root.appendingPathComponent("latest-check")
        let now = Date().timeIntervalSince1970
        var latest: String?
        if let text = try? String(contentsOf: stamp, encoding: .utf8),
           let line = text.split(separator: "\n", omittingEmptySubsequences: false).first,
           let at = Double(line), now - at < 86_400 {
            latest = text.split(separator: "\n").dropFirst().first.map(String.init)
        } else {
            let r = await Shell.run("/usr/bin/curl", ["-fsSL", "-m", "2", "https://api.github.com/repos/\(repo)/releases/latest"])
            if r.code == 0,
               let json = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [String: Any],
               let tag = json["tag_name"] as? String {
                latest = normalized(tag)
            }
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? "\(Int(now))\n\(latest ?? "")\n".write(to: stamp, atomically: true, encoding: .utf8)
        }
        guard let latest, isNewer(latest, than: ReticleVersion.current) else { return nil }
        return "reticle \(latest) is available (this is \(ReticleVersion.current)); run `reticle update`"
    }
}

let updateUsage = "usage: reticle update [--to <version>]"

func cmdUpdate(_ args: Args) async throws {
    if let from = args.option("from") {
        // What install.sh runs with the freshly unpacked release.
        try await ReticleInstall.activate(URL(fileURLWithPath: from)).forEach { print($0) }
        return
    }
    let target: String
    if let to = args.option("to") {
        target = ReticleInstall.normalized(to)
    } else {
        target = try await ReticleInstall.latestVersion()
    }
    if ReticleInstall.activeVersion == target {
        print("already on reticle \(target)")
        ReticleSkill.refreshInstalled().forEach { print($0) }
        return
    }
    let unpacked = ReticleInstall.versions.appendingPathComponent(target)
    let dir = FileManager.default.isExecutableFile(atPath: unpacked.appendingPathComponent("bin/reticle-host").path)
        ? unpacked
        : try await ReticleInstall.download(target)
    defer {
        if dir != unpacked { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    }
    try await ReticleInstall.activate(dir).forEach { print($0) }
}
