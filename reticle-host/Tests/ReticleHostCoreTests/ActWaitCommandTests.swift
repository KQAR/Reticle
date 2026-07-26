import Foundation
import Testing
@testable import ReticleHostCore

/// Records the RPC a CLI command actually sends, and replies with a canned result.
private final class RecordingBackend: HelperCalling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(method: String, params: [String: Any])] = []
    var reply: [String: Any] = [:]

    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        lock.lock()
        calls.append((method, params))
        lock.unlock()
        return reply
    }
}

/// The `act wait` CLI → RPC mapping, and the exit code it projects.
///
/// This suite exists because the first version of `cmdActWait` silently dropped
/// `--point`, so the helper's by-name refusal ("a coordinate always resolves") was
/// unreachable through the CLI and users got a generic "needs a predicate"
/// instead. Every unit test passed — the gap was in the argument mapping, one
/// layer above them — and only the e2e caught it. These assertions pin the layer
/// that was missing coverage.
@Suite(.serialized)
struct ActWaitCommandTests {

    private func run(_ argv: [String], reply: [String: Any]) throws -> (Int32, RecordingBackend) {
        let backend = RecordingBackend()
        backend.reply = reply
        let code = try cmdAct(backend, Args(argv))
        return (code, backend)
    }

    private func resolvedReply() -> [String: Any] {
        [
            "gesture": "wait", "predicate": "appear testId=x", "outcome": "resolved",
            "elapsedMs": 12, "timeoutMs": 10_000, "polls": 1, "treeChanges": 0,
            "sinceLastChangeMs": 12,
        ]
    }

    @Test func forwardsEverySelectorTheHelperMustBeAbleToRefuse() throws {
        // point and alias are unusable for a wait, but the helper is the thing that
        // says so by name. They MUST reach it.
        let (_, backend) = try run(
            ["act", "wait", "--package", "p", "--point", "10,20"],
            reply: resolvedReply()
        )
        #expect(backend.calls.count == 1)
        #expect(backend.calls[0].params["point"] as? String == "10,20")

        let (_, aliased) = try run(
            ["act", "wait", "--package", "p", "--test-id", "x", "--alias", "@1"],
            reply: resolvedReply()
        )
        #expect(aliased.calls[0].params["alias"] as? String == "@1")
        #expect(aliased.calls[0].params["testId"] as? String == "x")
    }

    @Test func mapsPredicateFlagsOntoTheWireNames() throws {
        let (_, backend) = try run(
            [
                "act", "wait", "--package", "p", "--for", "#cart.total",
                "--text", "Paid", "--timeout", "4000", "--quiet-for", "250",
            ],
            reply: resolvedReply()
        )
        let params = backend.calls[0].params
        #expect(params["gesture"] as? String == "wait")
        #expect(params["for"] as? String == "#cart.total")
        // `--text` on a wait means "contains", not `type`'s "send this text": it is
        // renamed on the wire so a batch step can never be read as a type.
        #expect(params["textContains"] as? String == "Paid")
        #expect(params["text"] == nil)
        #expect(params["timeoutMs"] as? Int == 4000)
        #expect(params["quietMs"] as? Int == 250)
    }

    @Test func goneAndIdleAreSentAsBooleans() throws {
        let (_, gone) = try run(
            ["act", "wait", "--package", "p", "--test-id", "t", "--gone"],
            reply: resolvedReply()
        )
        #expect(gone.calls[0].params["gone"] as? Bool == true)
        let (_, idle) = try run(["act", "wait", "--package", "p", "--idle"], reply: resolvedReply())
        #expect(idle.calls[0].params["idle"] as? Bool == true)
    }

    @Test func exitIsZeroWithoutStrictWhateverTheOutcome() throws {
        // A predicate that did not come true is an observation, not a tool failure,
        // and a non-zero exit reads as "the command broke" to an agent driving this
        // through a shell.
        for outcome in ["resolved", "absent", "unknowable"] {
            var reply = resolvedReply()
            reply["outcome"] = outcome
            let (code, _) = try run(["act", "wait", "--package", "p", "--test-id", "t"], reply: reply)
            #expect(code == 0, "outcome \(outcome) must exit 0 without --strict")
        }
    }

    @Test func strictProjectsTheOutcomeOntoDistinctExitCodes() throws {
        // 3 and 4 must never collapse: an agent may act on `absent` ("not there")
        // but must only switch tactics on `unknowable` ("I could not see").
        let expected: [String: Int32] = ["resolved": 0, "absent": 3, "unknowable": 4]
        for (outcome, want) in expected {
            var reply = resolvedReply()
            reply["outcome"] = outcome
            let (code, _) = try run(
                ["act", "wait", "--package", "p", "--test-id", "t", "--strict"],
                reply: reply
            )
            #expect(code == want, "outcome \(outcome) under --strict should exit \(want), got \(code)")
        }
    }

    @Test func anUnrecognizedOutcomeIsAnErrorUnderStrict() throws {
        // A helper that grew a fourth outcome must not be reported as success.
        var reply = resolvedReply()
        reply["outcome"] = "something-new"
        let (code, _) = try run(
            ["act", "wait", "--package", "p", "--test-id", "t", "--strict"],
            reply: reply
        )
        #expect(code == 1)
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

    private final class ScriptedBackend: HelperCalling, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [[String: Any]] = []
        var replies: [[String: Any]] = []

        func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            lock.lock()
            let index = calls.count
            calls.append(params)
            lock.unlock()
            return index < replies.count ? replies[index] : [:]
        }
    }

    private func stepsFile(_ json: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("reticle-wait-batch-\(UUID().uuidString.prefix(8)).json")
        try json.write(to: path, atomically: true, encoding: .utf8)
        return path.path
    }

    private func waitReply(_ outcome: String, reasons: [String] = []) -> [String: Any] {
        var r: [String: Any] = [
            "gesture": "wait", "predicate": "text testId=s contains \"Paid\"", "outcome": outcome,
            "elapsedMs": 10, "timeoutMs": 3000, "polls": 2, "treeChanges": 0, "sinceLastChangeMs": 10,
        ]
        if !reasons.isEmpty { r["reasons"] = reasons }
        return r
    }

    @Test func aStrictWaitStepStopsTheBatch() throws {
        let file = try stepsFile("""
        [
          { "gesture": "tap", "testId": "pay" },
          { "gesture": "wait", "testId": "s", "textContains": "Paid", "strict": true },
          { "gesture": "tap", "testId": "done" }
        ]
        """)
        let backend = ScriptedBackend()
        backend.replies = [
            ["gesture": "tap"],
            waitReply("unknowable", reasons: ["window-unfocused"]),
            ["gesture": "tap"],
        ]
        #expect(throws: (any Error).self) {
            try cmdAct(backend, Args(["act", "batch", "--package", "p", "--file", file]))
        }
        // The third step must never have been dispatched.
        #expect(backend.calls.count == 2)
        try? FileManager.default.removeItem(atPath: file)
    }

    @Test func aNonStrictWaitStepRecordsAndCarriesOn() throws {
        let file = try stepsFile("""
        [
          { "gesture": "wait", "testId": "s", "textContains": "Paid" },
          { "gesture": "tap", "testId": "done" }
        ]
        """)
        let backend = ScriptedBackend()
        backend.replies = [waitReply("absent"), ["gesture": "tap"]]
        let code = try cmdAct(backend, Args(["act", "batch", "--package", "p", "--file", file]))
        #expect(code == 0)
        #expect(backend.calls.count == 2, "a non-strict wait must not gate the batch")
        try? FileManager.default.removeItem(atPath: file)
    }

    @Test func aStrictWaitThatResolvesDoesNotStopTheBatch() throws {
        let file = try stepsFile("""
        [
          { "gesture": "wait", "testId": "s", "textContains": "Paid", "strict": true },
          { "gesture": "tap", "testId": "done" }
        ]
        """)
        let backend = ScriptedBackend()
        backend.replies = [waitReply("resolved"), ["gesture": "tap"]]
        _ = try cmdAct(backend, Args(["act", "batch", "--package", "p", "--file", file]))
        #expect(backend.calls.count == 2)
        try? FileManager.default.removeItem(atPath: file)
    }
}
