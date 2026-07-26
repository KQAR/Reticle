/// Event store errors surfaced through HTTP responses.
enum EventStoreError: Error, CustomStringConvertible {
    case invalidSession(String)
    case sessionNotFound(String)

    var description: String {
        switch self {
        case .invalidSession(let id):
            "invalid session id: \(id)"
        case .sessionNotFound(let id):
            "session not found: \(id)"
        }
    }
}
