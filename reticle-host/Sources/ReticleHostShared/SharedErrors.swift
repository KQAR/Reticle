import Foundation

/// Error surfaced by the Kotlin helper or by the JSONL process boundary. Lives in
/// the shared foundation layer because the network lane throws it too (mock and
/// certificate failures) and must not depend on the host's helper-client code.
public struct HelperError: Error, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
