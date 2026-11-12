import Foundation
import Testing
@testable import ReticleHostCore

/// A helper transport that answers `snapshot` with a canned tree (or an error)
/// and `act` with a canned tap, recording every call.
final class SnapshotTransport: HelperCalling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(method: String, params: [String: Any])] = []
    var snapshot: String
    var failSnapshot = false

    init(_ snapshot: String) { self.snapshot = snapshot }

    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        lock.lock()
        calls.append((method, params))
        lock.unlock()
        if method == "snapshot" {
            if failSnapshot { throw HelperError("no Reticle runtime for 'p' (connection refused)") }
            return ["snapshot": try JSONSerialization.jsonObject(with: Data(snapshot.utf8))]
        }
        return ["gesture": "tap"]
    }

    var methods: [String] { lock.lock(); defer { lock.unlock() }; return calls.map(\.method) }

    /// A one-node screen: `testId` carrying `text`, or an empty screen when nil.
    static func screen(testId: String? = nil, text: String = "") -> String {
        let child = testId.map { id in
            #"""
            ,"n":{"ref":"n","parentRef":"app","kind":"view","typeName":"android.widget.TextView",
              "testId":"\#(id)","text":"\#(text)","frame":{"x":0,"y":100,"width":200,"height":40},"isVisible":true}
            """#
        } ?? ""
        return #"""
        {"schemaVersion":1,"capturedAtMillis":1,"platform":"android",
         "screen":{"size":{"width":1080,"height":2400},"density":3},"rootRef":"app","nodes":{
          "app":{"ref":"app","kind":"application","typeName":"Application","children":[\#(testId == nil ? "" : "\"n\"")]}\#(child)}}
        """#
    }
}

/// `act wait` on Android: the CLI flags, the host-side `WaitRunner` over the
/// helper's `snapshot` primitive, and the exit code it projects.
///
/// Driven through `AndroidBackend` over a fake *transport*, so the whole chain is
/// asserted: CLI flags -> `ActRequest` -> predicate -> `snapshot` RPCs -> verdict.
/// The first version of `cmdActWait` silently dropped `--point`, so the by-name
/// refusal was unreachable through the CLI; the refusal tests pin that layer.
@Suite(.serialized)
struct ActWaitCommandTests {

    private func run(_ argv: [String], screen: String) async throws -> (Int32, SnapshotTransport) {
        let transport = SnapshotTransport(screen)
        let code = try await cmdAct(AndroidBackend(transport), Args(argv))
        return (code, transport)
    }

    private func refusal(_ argv: [String]) async -> (String, SnapshotTransport) {
        let transport = SnapshotTransport(SnapshotTransport.screen())
        do {
            _ = try await cmdAct(AndroidBackend(transport), Args(argv))
            return ("", transport)
        } catch { return ("\(error)", transport) }
    }

    @Test func pointAndAliasAreRefusedByNameBeforeAnyDeviceCall() async {
        let (point, p) = await refusal(["act", "wait", "--package", "p", "--point", "10,20"])
        #expect(point.contains("wait cannot take --point"))
        #expect(p.calls.isEmpty)
        let (alias, a) = await refusal(["act", "wait", "--package", "p", "--test-id", "x", "--alias", "@1"])
        #expect(alias.contains("wait cannot take --alias"))
        #expect(a.calls.isEmpty, "an alias must not be resolved against the cache, nor sent anywhere")
    }

    @Test func runsInTheHostOverSnapshotAndProbesOnlyTheFirstFetch() async throws {
        // `--idle --quiet-for 0` resolves on the second poll: two fetches.
        let (code, transport) = try await run(
            ["act", "wait", "--package", "p", "--idle", "--quiet-for", "0", "--strict"],
            screen: SnapshotTransport.screen()
        )
        #expect(code == 0)
        #expect(transport.methods == ["snapshot", "snapshot"], "wait never calls the helper's act")
        #expect(transport.calls.map { $0.params["probe"] as? Bool } == [true, false])
        #expect(transport.calls.allSatisfy { $0.params["package"] as? String == "p" })
    }

    @Test func textAndForReachThePredicate() async throws {
        let paid = SnapshotTransport.screen(testId: "cart.total", text: "Total: Paid")
        let (hit, _) = try await run(
            ["act", "wait", "--package", "p", "--for", "#cart.total", "--text", "Paid", "--strict"], screen: paid
        )
        #expect(hit == 0)
        let (miss, _) = try await run(
            ["act", "wait", "--package", "p", "--for", "#cart.total", "--text", "Refunded",
             "--timeout", "50", "--quiet-for", "0", "--strict"],
            screen: paid
        )
        #expect(miss == 3, "the node resolved but holds other text: absent")
    }

    @Test func exitIsZeroWithoutStrictWhateverTheOutcome() async throws {
        // A predicate that did not come true is an observation, not a tool failure.
        let (code, _) = try await run(
            ["act", "wait", "--package", "p", "--test-id", "t", "--timeout", "0"], screen: SnapshotTransport.screen()
        )
        #expect(code == 0)
    }

    @Test func strictProjectsTheOutcomeOntoDistinctExitCodes() async throws {
        // 3 and 4 must never collapse: an agent may act on `absent` ("not there")
        // but must only switch tactics on `unknowable` ("I could not see").
        let (resolved, _) = try await run(
            ["act", "wait", "--package", "p", "--test-id", "t", "--strict"], screen: SnapshotTransport.screen(testId: "t")
        )
        #expect(resolved == 0)
        let (absent, _) = try await run(
            ["act", "wait", "--package", "p", "--test-id", "t", "--timeout", "50", "--quiet-for", "0", "--strict"],
            screen: SnapshotTransport.screen()
        )
        #expect(absent == 3)
        // A zero budget never sees the screen settle: tree-still-changing.
        let (unknowable, _) = try await run(
            ["act", "wait", "--package", "p", "--test-id", "t", "--timeout", "0", "--strict"],
            screen: SnapshotTransport.screen()
        )
        #expect(unknowable == 4)
    }

    @Test func aFailedSnapshotIsAnErrorNotUnknowable() async {
        // "Could not see the state" and "the tool broke" are different answers.
        let transport = SnapshotTransport(SnapshotTransport.screen())
        transport.failSnapshot = true
        await #expect(throws: HelperError.self) {
            try await cmdAct(AndroidBackend(transport), Args(["act", "wait", "--package", "p", "--test-id", "t"]))
        }
    }
}

/// A `wait` step inside `act batch`.
///
/// Batch is host-side sequencing, and the usual reason to put a wait in a flow is
/// to GATE it — "do not run the next step until the screen is ready". But a wait
/// never throws on its own (a predicate that did not come true is an observation),
/// so the gate has to be opt-in per step.
@Suite(.serialized)
struct ActWaitBatchTests {

    private func stepsFile(_ json: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("reticle-wait-batch-\(UUID().uuidString.prefix(8)).json")
        try json.write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    private func batch(_ json: String, screen: String) async throws -> SnapshotTransport {
        let file = try stepsFile(json)
        defer { try? FileManager.default.removeItem(atPath: file) }
        let transport = SnapshotTransport(screen)
        _ = try await cmdAct(AndroidBackend(transport), Args(["act", "batch", "--package", "p", "--file", file]))
        return transport
    }

    @Test func aStrictWaitStepStopsTheBatch() async throws {
        let file = try stepsFile("""
        [
          { "gesture": "tap", "testId": "pay" },
          { "gesture": "wait", "testId": "s", "textContains": "Paid", "timeoutMs": 0, "strict": true },
          { "gesture": "tap", "testId": "done" }
        ]
        """)
        defer { try? FileManager.default.removeItem(atPath: file) }
        let transport = SnapshotTransport(SnapshotTransport.screen())
        await #expect(throws: (any Error).self) {
            try await cmdAct(AndroidBackend(transport), Args(["act", "batch", "--package", "p", "--file", file]))
        }
        // The third step must never have been dispatched.
        #expect(transport.methods.filter { $0 == "act" }.count == 1)
    }

    @Test func aNonStrictWaitStepRecordsAndCarriesOn() async throws {
        let transport = try await batch("""
        [
          { "gesture": "wait", "testId": "s", "textContains": "Paid", "timeoutMs": 0 },
          { "gesture": "tap", "testId": "done" }
        ]
        """, screen: SnapshotTransport.screen())
        #expect(transport.methods.last == "act", "a non-strict wait must not gate the batch")
    }

    @Test func aStrictWaitThatResolvesDoesNotStopTheBatch() async throws {
        let transport = try await batch("""
        [
          { "gesture": "wait", "testId": "s", "textContains": "Paid", "strict": true },
          { "gesture": "tap", "testId": "done" }
        ]
        """, screen: SnapshotTransport.screen(testId: "s", text: "Paid"))
        #expect(transport.methods == ["snapshot", "act"])
    }
}
