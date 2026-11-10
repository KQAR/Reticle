import Foundation
import ReticleHostShared

/// A helper transport that is only brought up when something calls it.
///
/// Commands that the host now answers on its own — rendering a snapshot file —
/// never touch the helper, and must not fail because no helper binary is around or
/// pay for spawning one. The first `call` connects; a connection failure (including
/// `HelperUnavailable`) surfaces from that call, where the CLI already handles it.
final class LazyHelperClient: HelperCalling, @unchecked Sendable {
    private let connect: () throws -> HelperCalling
    private let lock = NSLock()
    private var client: HelperCalling?

    init(_ connect: @escaping () throws -> HelperCalling) {
        self.connect = connect
    }

    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        try transport().call(method, params)
    }

    func close() {
        lock.lock()
        let current = client
        client = nil
        lock.unlock()
        current?.close()
    }

    private func transport() throws -> HelperCalling {
        lock.lock()
        defer { lock.unlock() }
        if let client { return client }
        let made = try connect()
        client = made
        return made
    }
}
