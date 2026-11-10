import CryptoKit
import Foundation
import ReticleHostShared
import ReticleProtocol

/// The short-lived `@N` cache `ui outline` writes and `act --alias @N` reads.
///
/// Moved from the Kotlin helper with no change to the file: same path
/// (`~/.reticle/aliases/<serial>/<package>/last-outline.json`), same version-1
/// shape, so an outline cached by an older helper still resolves.
enum OutlineAliasCache {
    static let version = 1

    private struct File: Codable {
        struct Screen: Codable { var width: Double; var height: Double; var density: Double }
        var version: Int
        var serial: String
        var package: String
        var capturedAtMillis: Int64
        var screen: Screen
        var entries: [Outline.Entry]
    }

    static func write(_ snapshot: Snapshot, _ entries: [Outline.Entry], serial: String?, package: String,
                      home: URL = defaultHome) throws {
        let file = cacheFile(serial: serial, package: package, home: home)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = File(
            version: version, serial: serial ?? "", package: package,
            capturedAtMillis: snapshot.capturedAtMillis,
            screen: .init(width: snapshot.screen.size.width, height: snapshot.screen.size.height,
                          density: snapshot.screen.density),
            entries: entries
        )
        // Atomic, so a crash mid-write cannot leave a truncated cache that breaks
        // the next alias resolution.
        try JSONEncoder().encode(payload).write(to: file, options: .atomic)
    }

    static func resolve(_ alias: String, serial: String?, package: String, home: URL = defaultHome) throws -> Outline.Entry {
        let rerun = "Re-run `reticle ui outline --live --package \(package)`"
        let file = cacheFile(serial: serial, package: package, home: home)
        guard let data = try? Data(contentsOf: file) else {
            throw HelperError("no outline alias cache for '\(package)'. Run `reticle ui outline --live --package \(package)` first.")
        }
        struct Versioned: Decodable { var version: Int? }
        guard let versioned = try? JSONDecoder().decode(Versioned.self, from: data) else {
            throw HelperError("outline alias cache for '\(package)' is corrupt (unreadable JSON). \(rerun).")
        }
        guard versioned.version == version else {
            throw HelperError("outline alias cache version mismatch. \(rerun).")
        }
        let cache: File
        do {
            cache = try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw HelperError("outline alias cache for '\(package)' is corrupt (\(error)). \(rerun).")
        }
        guard let entry = cache.entries.first(where: { $0.alias == alias }) else {
            let known = cache.entries.prefix(12).map(\.alias).joined(separator: ", ")
            throw HelperError("outline alias '\(alias)' not found. Cached aliases: \(known). "
                + "Re-run `reticle ui outline --live` after navigation.")
        }
        return entry
    }

    static var defaultHome: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func cacheFile(serial: String?, package: String, home: URL) -> URL {
        home.appendingPathComponent(".reticle/aliases/\(sanitize(serial ?? "default"))/\(sanitize(package))/last-outline.json")
    }

    /// Path-safe, and bounded: a long id keeps a readable prefix plus a digest.
    static func sanitize(_ value: String) -> String {
        let safe = String(value.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "_" })
        guard safe.count > 80 else { return safe }
        let digest = SHA256.hash(data: Data(value.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return safe.prefix(72) + "-" + digest
    }
}
