import Foundation
import ReticleHostShared

/// The narrow surface the network lane needs from the host's session store: a
/// place to write captured `network.*` events and the session directory where
/// request/response bodies are persisted. Declared here (not in the host) so the
/// lane compiles and tests independently of the daemon; `EventStore` conforms to
/// it in ReticleHostCore. `emit` is best-effort by contract — capture must never
/// fail a proxied request just because an event couldn't be recorded.
public protocol NetworkEventSink: AnyObject, Sendable {
    var sessionDirectory: URL { get }
    func emit(_ request: EventPostRequest)
}
