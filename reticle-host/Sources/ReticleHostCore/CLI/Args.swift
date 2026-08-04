import Foundation

/// Parsed command-line arguments for the Reticle host.
public struct Args {
    private var positionals: [String] = []
    private var options: [String: String] = [:]

    /// Creates an argument view from the process arguments after the executable name.
    public init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
                    options[key] = argv[i + 1]
                    i += 2
                } else {
                    options[key] = "true"
                    i += 1
                }
            } else {
                positionals.append(a)
                i += 1
            }
        }
    }

    /// Returns the positional argument at `idx`, if present.
    public func positional(_ idx: Int) -> String? {
        idx < positionals.count ? positionals[idx] : nil
    }

    /// Every `--name` the invocation carried, so a command can report the ones it
    /// does not read instead of dropping them (see `CliFlags`).
    public var optionNames: [String] { Array(options.keys) }

    /// Returns the value for a `--name` option, or `"true"` for bare flags.
    public func option(_ name: String) -> String? {
        options[name]
    }

    /// Whether a boolean flag is set. A bare `--settle` parses as `"true"`, and an
    /// explicit `--settle false` turns it off — the same two-line dance that used to
    /// be repeated at every flag site.
    public func flag(_ name: String) -> Bool {
        guard let value = options[name] else { return false }
        return value != "false"
    }

    /// Returns a required option or throws a CLI-facing error.
    public func require(_ name: String) throws -> String {
        guard let v = options[name] else {
            throw HelperError("missing required --\(name)")
        }
        return v
    }

    /// Returns a `--name` option parsed as an integer, or nil when absent.
    ///
    /// A value that is present but not an integer throws by name instead of
    /// silently substituting a default — `--depth x` used to parse as depth 0
    /// and render an EMPTY tree, which reads as "the screen is blank" rather
    /// than "the flag was mistyped".
    public func intOption(_ name: String) throws -> Int? {
        guard let raw = options[name] else { return nil }
        guard let value = Int(raw) else {
            throw HelperError("--\(name) must be an integer (got '\(raw)')")
        }
        return value
    }
}
