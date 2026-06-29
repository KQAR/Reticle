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

    /// Returns the value for a `--name` option, or `"true"` for bare flags.
    public func option(_ name: String) -> String? {
        options[name]
    }

    /// Returns a required option or throws a CLI-facing error.
    public func require(_ name: String) throws -> String {
        guard let v = options[name] else {
            throw HelperError("missing required --\(name)")
        }
        return v
    }
}
