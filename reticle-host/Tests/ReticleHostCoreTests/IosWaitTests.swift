import Foundation
import Testing
import ReticleProtocol
@testable import ReticleHostCore

/// The iOS `act wait` poll loop, driven with an injected clock and snapshot source
/// so the timing behaviour is pinned without a simulator.
///
/// The classification itself is covered by the shared fixture table in
/// ReticleProtocol's suite; what is tested here is the loop around it — budget,
/// backoff, quiescence bookkeeping, early exit, and the argument refusals.
@Suite(.serialized)
struct IosWaitTests {

    /// A snapshot with one node, so a selector can resolve or miss on demand.
    private func snapshot(testId: String?, text: String? = nil, visible: Bool = true) -> Snapshot {
        var nodes: [String: Node] = [
            "r0": Node(
                ref: "r0",
                kind: .application,
                typeName: "UIApplication",
                role: "application",
                children: testId == nil ? [] : ["r1"]
            )
        ]
        if let testId {
            nodes["r1"] = Node(
                ref: "r1",
                parentRef: "r0",
                kind: .view,
                typeName: "UILabel",
                role: "text",
                text: text,
                testId: testId,
                frame: Rect(x: 0, y: 0, width: 100, height: 40),
                isVisible: visible,
                isInteractive: true
            )
        }
        return Snapshot(
            capturedAtMillis: 0,
            platform: "ios",
            screen: ScreenInfo(size: Size(width: 390, height: 844), density: 3),
            rootRef: "r0",
            nodes: nodes
        )
    }

    /// A runner whose clock advances only when the loop sleeps, so a "10s" budget
    /// costs no wall-clock time and the assertions are deterministic.
    private func runner(_ snapshots: [Snapshot]) -> IosWaitRunner {
        let clock = Clock()
        var index = 0
        var r = IosWaitRunner(fetch: {
            let s = snapshots[min(index, snapshots.count - 1)]
            index += 1
            return s
        })
        r.now = { clock.millis }
        r.sleep = { clock.millis += $0 }
        return r
    }

    private final class Clock {
        var millis = 0
    }

    @Test func resolvesOnTheFirstPollWhenAlreadyThere() throws {
        let r = runner([snapshot(testId: "cart.total")])
        let out = try r.run(
            predicate: WaitPredicate(kind: .appear, selector: ReticleProtocol.Selector(testId: "cart.total")),
            timeoutMs: 10_000,
            quietMs: 400
        )
        #expect(out["outcome"] as? String == "resolved")
        #expect(out["polls"] as? Int == 1)
        // Must not burn the budget once satisfied.
        #expect((out["elapsedMs"] as? Int ?? .max) == 0)
        #expect(out["predicate"] as? String == "appear testId=cart.total")
        #expect(out["ref"] as? String == "r1")
    }

    @Test func resolvesWhenTheNodeArrivesLater() throws {
        // Missing for the first two polls, then present.
        let r = runner([
            snapshot(testId: nil),
            snapshot(testId: nil),
            snapshot(testId: "cart.total"),
        ])
        let out = try r.run(
            predicate: WaitPredicate(kind: .appear, selector: ReticleProtocol.Selector(testId: "cart.total")),
            timeoutMs: 10_000,
            quietMs: 400
        )
        #expect(out["outcome"] as? String == "resolved")
        #expect(out["polls"] as? Int == 3)
        // Two 100ms backoff steps in the dense phase.
        #expect(out["elapsedMs"] as? Int == 200)
    }

    @Test func aMissOnASettledScreenIsAnHonestAbsent() throws {
        let r = runner([snapshot(testId: nil)])
        let out = try r.run(
            predicate: WaitPredicate(kind: .appear, selector: ReticleProtocol.Selector(testId: "cart.total")),
            timeoutMs: 1_000,
            quietMs: 400
        )
        #expect(out["outcome"] as? String == "absent")
        #expect(out["reasons"] == nil, "an honest negative carries no blocking reason")
        #expect((out["next"] as? [String])?.contains("ui compact --live to see what IS on screen") == true)
    }

    @Test func neverOverrunsTheBudget() throws {
        let r = runner([snapshot(testId: nil)])
        let out = try r.run(
            predicate: WaitPredicate(kind: .appear, selector: ReticleProtocol.Selector(testId: "nope")),
            timeoutMs: 1_050,
            quietMs: 400
        )
        // The last sleep is clamped to the remaining budget rather than a full
        // backoff step, so the reported elapsed time is never later than asked.
        let elapsed = out["elapsedMs"] as? Int ?? .max
        #expect(elapsed >= 1_050)
        #expect(elapsed <= 1_050, "elapsed \(elapsed) overran the 1050ms budget")
    }

    @Test func idleReturnsAsSoonAsTheScreenIsQuiet() throws {
        let r = runner([snapshot(testId: "a")])
        let out = try r.run(predicate: WaitPredicate(kind: .idle), timeoutMs: 30_000, quietMs: 400)
        #expect(out["outcome"] as? String == "resolved")
        #expect(out["predicate"] as? String == "idle")
        // Needs two polls to have a digest to compare, then the quiet window.
        #expect(out["polls"] as? Int == 5)
        #expect(out["elapsedMs"] as? Int == 400)
        #expect(out["treeChanges"] as? Int == 0)
    }

    @Test func idleOnANeverSettlingScreenIsUnknowable() throws {
        // Every poll differs, so the digest never repeats.
        let r = runner((0..<400).map { snapshot(testId: "a", text: "tick \($0)") })
        let out = try r.run(predicate: WaitPredicate(kind: .idle), timeoutMs: 2_000, quietMs: 400)
        #expect(out["outcome"] as? String == "unknowable")
        #expect((out["reasons"] as? [String]) == ["tree-still-changing"])
        #expect((out["treeChanges"] as? Int ?? 0) > 1)
    }

    @Test func textPredicateReportsWhatWasActuallyThere() throws {
        let r = runner([snapshot(testId: "status", text: "Cart: 3 items")])
        let out = try r.run(
            predicate: WaitPredicate(
                kind: .text,
                selector: ReticleProtocol.Selector(testId: "status"),
                textContains: "Paid"
            ),
            timeoutMs: 800,
            quietMs: 400
        )
        #expect(out["outcome"] as? String == "absent")
        #expect(out["observedText"] as? String == "Cart: 3 items")
    }

    @Test func aResolvableButInvisibleNodeStillCountsAsAppeared() throws {
        // The case the dropped isVisible-based proposal got wrong.
        let r = runner([snapshot(testId: "status", text: "hi", visible: false)])
        let out = try r.run(
            predicate: WaitPredicate(kind: .appear, selector: ReticleProtocol.Selector(testId: "status")),
            timeoutMs: 800,
            quietMs: 400
        )
        #expect(out["outcome"] as? String == "resolved")
        #expect((out["caveats"] as? [String]) == ["resolved-but-not-visible"])
    }

    @Test func predicateParsingMatchesTheVerifyTokenGrammar() throws {
        #expect(try IosWaitRunner.predicate(from: ["for": "#cart.total"]).describe() == "appear testId=cart.total")
        #expect(try IosWaitRunner.predicate(from: ["for": "@status"]).describe() == "appear resourceId=status")
        #expect(try IosWaitRunner.predicate(from: ["for": "css=#pay"]).describe() == "appear css=#pay")
        #expect(try IosWaitRunner.predicate(from: ["for": "r7"]).describe() == "appear ref=r7")
        #expect(try IosWaitRunner.predicate(from: ["testId": "x", "gone": true]).describe() == "gone testId=x")
        #expect(
            try IosWaitRunner.predicate(from: ["testId": "x", "textContains": "Paid"]).describe()
                == "text testId=x contains \"Paid\""
        )
        #expect(try IosWaitRunner.predicate(from: ["idle": true]).describe() == "idle")
        #expect(try IosWaitRunner.predicate(from: ["for": "idle"]).describe() == "idle")
    }

    @Test func refusesPredicatesItCannotAnswer() {
        // Each refusal exists because the alternative is a wait that always
        // "succeeds" and therefore means nothing.
        #expect(throws: (any Error).self) { try IosWaitRunner.predicate(from: [:]) }
        #expect(throws: (any Error).self) {
            try IosWaitRunner.predicate(from: ["testId": "x", "point": "10,20"])
        }
        #expect(throws: (any Error).self) {
            try IosWaitRunner.predicate(from: ["testId": "x", "alias": "@1"])
        }
        #expect(throws: (any Error).self) {
            try IosWaitRunner.predicate(from: ["testId": "x", "gone": true, "textContains": "y"])
        }
        #expect(throws: (any Error).self) {
            try IosWaitRunner.predicate(from: ["idle": true, "testId": "x"])
        }
        #expect(throws: (any Error).self) { try IosWaitRunner.parseWaitToken("bogus=1") }
    }
}
