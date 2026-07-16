import Foundation

/// Main-thread bridging. The server runs on a background queue, so capture /
/// screenshot / mutation (which touch UIKit and are `@MainActor`) hop to the main
/// thread. Mirrors the Android agent's `runOnMainSync`.
enum MainThread {
    /// Run `work` on the main thread and return its result. Safe to call from a
    /// background queue; if already on main, runs inline to avoid deadlock.
    /// `MainActor.assumeIsolated` is valid because we are provably on the main
    /// thread inside the closure.
    static func sync<T: Sendable>(_ work: @MainActor () throws -> T) rethrows -> T {
        if Thread.isMainThread {
            return try MainActor.assumeIsolated(work)
        }
        return try DispatchQueue.main.sync {
            try MainActor.assumeIsolated(work)
        }
    }

    static func async(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated(work)
        }
    }
}

#if canImport(UIKit)
import UIKit

/// Sets the device clipboard from inside the app process. The reliable way to
/// stage non-ASCII input (the host's key synthesis is ASCII-only); the app is
/// foreground, so this write is allowed. The host follows with a paste.
@MainActor
enum ClipboardWriter {
    static func set(_ text: String) {
        UIPasteboard.general.string = text
    }
}
#else
@MainActor
enum ClipboardWriter {
    static func set(_ text: String) {}
}
#endif
