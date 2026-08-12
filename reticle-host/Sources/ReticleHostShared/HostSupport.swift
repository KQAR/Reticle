import Foundation

/// Epoch milliseconds. One definition instead of the inline
/// `Int64(Date().timeIntervalSince1970 * 1000)` that was scattered across the
/// event store, runtime state, daemon discovery, and both proxy handlers.
public func currentMillis() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
}

/// One value carried out of an async `Task` (or a callback) to the synchronous
/// caller that is blocked waiting for it, with the wakeup owned alongside the
/// storage.
///
/// The host is a CLI: its command paths are synchronous, while the engines it
/// drives are async. Every such bridge used to be a hand-rolled trio — a
/// `DispatchSemaphore`, a bare `final class Box: @unchecked Sendable { var value }`,
/// and a comment promising the two were used in the right order. This replaces
/// the trio: the lock makes the hand-off a real happens-before edge instead of a
/// convention, and the semaphore cannot be forgotten because `wait` owns it.
/// NOTE ON THE LOCK: both types below carry a caller-supplied payload that is
/// NOT required to be Sendable — `Flow`, `Result<_, any Error>`, a UIKit-adjacent
/// value. `Mutex` cannot hold one: `withLock` passes the state as `inout sending`,
/// so a non-Sendable payload cannot be read back out. Everything else in the host
/// uses `Mutex`; these two keep `NSLock` because the alternative is constraining
/// every caller's payload to Sendable, which several of them cannot satisfy.
public final class OneShot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var value: Value?
    private var resolved = false

    public init() {}

    /// Deliver the value. Later deliveries are dropped rather than overwriting:
    /// a caller that already timed out has moved on, and the task it abandoned
    /// can still finish.
    public func resolve(_ value: Value) {
        lock.lock()
        guard !resolved else { return lock.unlock() }
        self.value = value
        resolved = true
        lock.unlock()
        ready.signal()
    }

    /// Block until `resolve` lands, or `seconds` passes. `nil` means the value
    /// never arrived — callers turn that into their own timeout error, since only
    /// they know what timed out.
    public func wait(seconds: TimeInterval) -> Value? {
        guard ready.wait(timeout: .now() + seconds) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Thread-safe one-shot result holder for bridging a URLSession completion
/// callback back to a synchronous (`DispatchSemaphore`) caller. Reading before
/// `set` returns the caller-supplied `fallback` — some callers only `set` on
/// failure and treat "no set" as success.
public final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private let fallback: Result<T, Error>

    public init(fallback: Result<T, Error>) {
        self.fallback = fallback
    }

    public var value: Result<T, Error> {
        lock.lock()
        defer { lock.unlock() }
        return result ?? fallback
    }

    public func set(_ value: Result<T, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }
}
