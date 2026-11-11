import Foundation
import ReticleHostShared
import ReticleProtocol

// The iOS half of targeting: reaching THIS target's agent and fetching its
// snapshot, plus what an action can say about a window it cannot see. The
// platform-neutral half (resolution, reach, settle, the DOM landing witness) lives
// in `ReticleHostAct.ActTargeting`.
extension IosHelperClient {
    /// A DOM node's own selector chain, when the ref names one. Typing has to be
    /// routed by what the target IS rather than by which flag named it: a DOM node
    /// has no UIKit responder whatever found it, so a `--ref` that lands on one
    /// takes the same page-level path `--css` does.
    func webChain(forRef ref: String, in snapshot: Snapshot) -> String? {
        guard let node = snapshot.nodes[ref], node.kind == .domNode else { return nil }
        return node.domCssSelector()
    }

    /// The one thing an action can say about a window it cannot see. `windowFocused`
    /// is read from `UIApplication.applicationState`, so false is not a guess about
    /// z-order — it is the system telling the app it is not the one receiving input,
    /// which on a device is the only trace another process's alert leaves.
    func inactiveWarning(_ snapshot: Snapshot?) -> String? {
        guard snapshot?.screen.windowFocused == false else { return nil }
        return "the app was NOT active when this was dispatched — another process's window "
            + "(a system prompt, which is in no tree and in no in-process screenshot) holds input. "
            + "Actions on this app's own content can be inert while still reporting success; "
            + "deal with that prompt first"
    }

    /// The agent for `pkg`, once it is known to run on THIS client's target.
    ///
    /// The port is derived from the bundle id and a simulator shares the Mac's
    /// loopback, so the same app on two simulators means two agents wanting one
    /// port: the second never binds, and every command aimed at its simulator is
    /// answered by the first one — reading `healthy` while observing the wrong
    /// screen. The agent reports which simulator it is in, so the first contact
    /// per bundle id checks it; later calls reuse the verdict.
    func agent(_ pkg: String) async throws -> IosAgentHTTP {
        let http = IosAgentHTTP(bundleId: pkg)
        if verifiedAgents.withLock({ $0.contains(pkg) }) { return http }
        // Unreachable is not a verdict: the call that follows reports it its own way.
        guard let info = await http.probeRuntime() else { return http }
        if let reason = await identityConflict(pkg: pkg, port: http.port, info: info) {
            throw HelperError(reason)
        }
        verifiedAgents.withLock { _ = $0.insert(pkg) }
        return http
    }

    /// Why the agent that answered `info` is not the one on this client's target,
    /// or nil when it is (or when nothing it says can tell). Shared by `agent(_:)`,
    /// which throws it, and `status`, which reports it.
    func identityConflict(pkg: String, port: Int, info: RuntimeInfo) async -> String? {
        if let answeredFrom = info.deviceId {
            guard let target = try? await Simctl.resolveUdid(serial) else { return nil }
            return Self.identityMismatch(pkg: pkg, port: port, answeredFrom: answeredFrom, target: target)
        }
        // A device cannot name itself, but it can say it is not a simulator —
        // which is a conflict only when the target is one.
        guard info.simulator == false, let target = try? await Simctl.resolveUdid(serial),
              await Simctl.isSimulator(target) else { return nil }
        return Self.deviceAnsweringForSimulator(pkg: pkg, port: port, target: target)
    }

    /// Why an agent answering from simulator `answeredFrom` is not the one on
    /// `target` (a simulator udid, or a device ECID), or nil when it is.
    ///
    /// An agent that names no simulator is not judged here: a device agent is
    /// `deviceAnsweringForSimulator`'s case, and an agent older than both fields
    /// passes, since refusing it would refuse every device.
    static func identityMismatch(pkg: String, port: Int, answeredFrom: String, target: String) -> String? {
        guard answeredFrom != target else { return nil }
        return "port conflict: '\(pkg)' on 127.0.0.1:\(port) is answered from simulator \(answeredFrom), "
            + "not the target \(target). The same app is running there too, and simulators share this "
            + "Mac's loopback port. Quit it (`xcrun simctl terminate \(answeredFrom) \(pkg)`) "
            + "or target it with --serial \(answeredFrom)"
    }

    /// A device's tunnel holds the port a simulator target's agent wanted, so the
    /// simulator command is answered from the phone.
    static func deviceAnsweringForSimulator(pkg: String, port: Int, target: String) -> String {
        "port conflict: '\(pkg)' on 127.0.0.1:\(port) is answered from a real device (through its "
            + "USB tunnel), not the target simulator \(target). The device tunnel holds the port this "
            + "simulator's app wanted. Stop that tunnel (the `iproxy` forwarding \(port)) and relaunch the app on "
            + "the simulator, or target the device with --serial <ECID>"
    }

    func fetchSnapshot(_ pkg: String) async throws -> Snapshot {
        let (data, _) = try await agent(pkg).get(Endpoints.snapshot)
        return try ReticleJSON.decode(Snapshot.self, from: data).requireSupportedSchema()
    }
}
