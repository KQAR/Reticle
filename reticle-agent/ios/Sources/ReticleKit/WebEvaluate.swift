#if canImport(WebKit)
import Foundation
import Synchronization
import WebKit

/// One value carried from a callback back to the thread that asked for it.
///
/// Five web probes used to hand-roll this as a bare `class Box { var value: String? }`
/// marked `@unchecked Sendable` with a comment claiming the semaphore made it
/// "race-free by construction". The claim was true, but it lived in prose: nothing
/// stopped a later edit from reading the field before the wait, and the compiler
/// had been told not to look. The `Mutex` here is what the comment used to assert —
/// and it makes the type plainly `Sendable` — while the semaphore is owned
/// alongside it so the two can no longer drift apart.
final class OneShotBox<Value: Sendable>: Sendable {
    private struct Held {
        var value: Value?
        var resolved = false
    }
    private let held = Mutex(Held())
    private let ready = DispatchSemaphore(value: 0)

    /// Deliver the answer. Later deliveries are dropped rather than overwriting:
    /// a waiter that already timed out is gone, and WebKit can still call back
    /// afterwards.
    func resolve(_ value: Value?) {
        let first = held.withLock { held -> Bool in
            guard !held.resolved else { return false }
            held.value = value
            held.resolved = true
            return true
        }
        if first { ready.signal() }
    }

    /// Block this thread until `resolve` lands or `timeout` passes. `nil` means
    /// either "no answer in time" or "the answer was nil" — every caller here
    /// treats those the same, and says so in what it returns.
    func wait(timeout: TimeInterval) -> Value? {
        guard ready.wait(timeout: .now() + timeout) == .success else { return nil }
        return held.withLock { $0.value }
    }
}

/// The one shape every WebKit read in this agent has: ask on the main thread,
/// block the server thread for the answer, give up after a budget.
///
/// The blocking is deliberate and cannot become `async`. The agent answers HTTP
/// on its own queue while the app's main thread runs the page; `evaluateJavaScript`
/// only calls back on main, so the server thread waits. Making the route handlers
/// async would not remove the wait — it would move it onto a cooperative-pool
/// thread, where blocking is worse.
enum WebEvaluate {
    /// - Parameter start: hands you a `finish` you must call exactly once with the
    ///   result; it runs on the main thread.
    /// - Returns: nil when the web view is detached, when JS answered nil, or when
    ///   the read outran `timeout` — indistinguishable to a caller, and reported
    ///   as such rather than as an empty page.
    static func onMain(
        in webView: WKWebView,
        timeout: TimeInterval,
        _ start: @escaping @MainActor @Sendable (@escaping @Sendable (String?) -> Void) -> Void
    ) -> String? {
        let box = OneShotBox<String>()
        DispatchQueue.main.async {
            // Provably on the main thread here, which is what `assumeIsolated`
            // asserts — and what lets `start` call WebKit's main-actor API
            // without the compiler taking it on faith.
            MainActor.assumeIsolated {
                // A web view that is not in a window has no content process to
                // ask, and `evaluateJavaScript` on one can hang instead of
                // erroring.
                guard webView.window != nil else { return box.resolve(nil) }
                start { box.resolve($0) }
            }
        }
        return box.wait(timeout: timeout)
    }

    /// The plain whole-page case: run `script` in the main frame.
    static func script(_ script: String, in webView: WKWebView, timeout: TimeInterval) -> String? {
        onMain(in: webView, timeout: timeout) { finish in
            webView.evaluateJavaScript(script) { value, _ in finish(value as? String) }
        }
    }
}
#endif
