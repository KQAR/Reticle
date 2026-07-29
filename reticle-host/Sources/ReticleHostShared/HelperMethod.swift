import Foundation

/// Every method name on the Android helper's JSONL RPC wire — the Swift copy of
/// the table in `reticle-protocol/helper-rpc.md`, which is the authority.
///
/// Two things become possible by naming them once as a type rather than as
/// sixteen string literals:
///
///  - **`AndroidBackend` spells a method through the compiler.** "The one place
///    the helper's method names are spelled" was true by convention; a typo in a
///    literal still compiled and failed at runtime on a device.
///  - **The daemon's helper broker can refuse anything else.**
///    `POST /helper/rpc` forwarded whatever `method` string a caller sent
///    straight into the helper process, which quietly undid the typed
///    `HostBackend` boundary the rest of the host is built on: the broker was a
///    stringly-typed side door into the same process. It is localhost-only, so
///    this is a boundary fix rather than a vulnerability — but a boundary with a
///    hole in it is not the boundary the architecture doc describes.
///
/// `HelperMethodContractTests` reads the markdown table and asserts these are the
/// same set, so a method added on one side fails the build instead of drifting.
public enum HelperMethod: String, CaseIterable, Sendable {
    case ping
    case listDevices
    case status
    case inject
    case launch
    case uiReport
    case act
    case mutate
    case logs
    case logcat
    case screenshot
    case render
    case proxyStatus
    case proxySet
    case proxyClear
    case proxyInstallCa

    /// Is this a method the helper wire contract knows about? The broker's gate.
    public static func isKnown(_ method: String) -> Bool {
        HelperMethod(rawValue: method) != nil
    }
}

public extension HelperCalling {
    @discardableResult
    func call(_ method: HelperMethod, _ params: [String: Any] = [:]) throws -> [String: Any] {
        try call(method.rawValue, params)
    }
}
