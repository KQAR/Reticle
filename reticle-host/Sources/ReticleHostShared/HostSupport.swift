import Foundation

/// Epoch milliseconds. One definition instead of the inline
/// `Int64(Date().timeIntervalSince1970 * 1000)` that was scattered across the
/// event store, runtime state, daemon discovery, and both proxy handlers.
public func currentMillis() -> Int64 {
    Int64(Date().timeIntervalSince1970 * 1000)
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
