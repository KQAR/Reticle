import Foundation

/// Which request keys are gesture inputs worth recording in an action trace
/// manifest's `params`, in the order a manifest and a digest list them.
///
/// The Swift copy of `dev.reticle.core.trace.ActionTraceParams`. It lives in the
/// shared layer because three consumers need it — the iOS trace writer, the
/// `trace log` renderer, and anything later that reads a manifest — and a third
/// hand-maintained copy of a list of strings is how the two that matter start
/// disagreeing.
///
/// An allow-list rather than a block-list: a new transport or bookkeeping key
/// added to the RPC should default to NOT being written into every evidence
/// package on disk.
///
/// Note what this means for `text`: a `type` action's text is recorded verbatim,
/// because "what did it type" is otherwise unanswerable from a trace — the
/// result only records a character count. Nothing in the capture layer marks a
/// field as secure, so Reticle cannot tell a password from a coupon code and
/// does not pretend to. See docs/boundaries.md.
public enum ActionTraceParamNames {
    public static let recorded: [String] = [
        // type
        "text", "submit", "typeDelayMs",
        // tap
        "settle", "noSettle", "settleTimeoutMs",
        // swipe / drag
        "from", "to", "duration",
        // scroll-to
        "container", "direction", "maxSwipes",
        // verify (the weak "did anything change" watch, not an assertion)
        "verify", "verifyTimeoutMs",
        // wait
        "for", "gone", "idle", "textContains", "timeoutMs", "quietMs",
    ]

    /// The gesture inputs from an act request, in `recorded` order so two traces
    /// of the same gesture read the same way. Absent keys are skipped rather
    /// than written as null — a manifest should not carry a field per gesture
    /// the action was not.
    public static func capture(from params: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for key in recorded {
            guard let value = params[key], !(value is NSNull) else { continue }
            out[key] = value as? String ?? "\(value)"
        }
        return out
    }
}
