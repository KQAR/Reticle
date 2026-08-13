import Foundation
import Testing
@testable import ReticleNetworkLane

/// The replay diff is the evidence Reticle emits for the capture → modify → replay
/// → diff loop, so its comparison logic is pinned here without a live proxy.
@Suite("Network replay diff")
struct NetworkReplayDiffTests {
    @Test func identicalResponsesReportNoChange() async {
        let diff = NetworkReplayDiff.between(
            sourceStatus: 200, sourceHeaders: ["Content-Type": "application/json"], sourceBody: Data("{}".utf8),
            replayStatus: 200, replayHeaders: ["content-type": "application/json"], replayBody: Data("{}".utf8)
        )
        #expect(diff.isIdentical)
        #expect(diff.statusChanged == false)
        #expect(diff.bodyChanged == false)
        #expect(diff.headersChanged.isEmpty)
    }

    @Test func statusAndBodyChangesAreDetected() async {
        let diff = NetworkReplayDiff.between(
            sourceStatus: 200, sourceHeaders: [:], sourceBody: Data("old".utf8),
            replayStatus: 500, replayHeaders: [:], replayBody: Data("new-longer".utf8)
        )
        #expect(diff.statusChanged)
        #expect(diff.statusFrom == 200)
        #expect(diff.statusTo == 500)
        #expect(diff.bodyChanged)
        #expect(diff.bodyBytesFrom == 3)
        #expect(diff.bodyBytesTo == 10)
        #expect(diff.isIdentical == false)
    }

    @Test func headerDeltasAreNameOnlyAndCaseInsensitive() async {
        let diff = NetworkReplayDiff.between(
            sourceStatus: 200, sourceHeaders: ["Authorization": "secret-a", "X-Old": "1"], sourceBody: nil,
            replayStatus: 200, replayHeaders: ["authorization": "secret-b", "X-New": "2"], replayBody: nil
        )
        // Authorization present in both but value differs -> changed (name only, no value leak).
        #expect(diff.headersChanged == ["authorization"])
        #expect(diff.headersRemoved == ["x-old"])
        #expect(diff.headersAdded == ["x-new"])
        // The secret value never appears anywhere in the diff.
        let encoded = String(data: try! JSONEncoder().encode(diff), encoding: .utf8)!
        #expect(!encoded.contains("secret-a"))
        #expect(!encoded.contains("secret-b"))
    }

    @Test func wholeBodyComparisonIsNotMarkedPartial() async {
        let diff = NetworkReplayDiff.between(
            sourceStatus: 200, sourceHeaders: [:], sourceBody: Data("{}".utf8),
            replayStatus: 200, replayHeaders: [:], replayBody: Data("{}".utf8)
        )
        // Omitted, not `false` — the common case stays unqualified on the wire.
        #expect(diff.bodyComparisonPartial == nil)
        #expect(diff.isIdentical)
    }

    /// Loom's capture cap can clip a body before Reticle ever sees it. Two clipped
    /// bodies that agree on their recorded prefix are NOT known to be equal, and this
    /// lane must not launder that into an "identical" verdict.
    @Test func cappedBodiesWithMatchingPrefixesRefuseToClaimIdentical() async {
        let prefix = Data(repeating: 0x41, count: 1024)
        let diff = NetworkReplayDiff.between(
            sourceStatus: 200, sourceHeaders: [:], sourceBody: prefix, sourceWireBytes: 5_000_000,
            replayStatus: 200, replayHeaders: [:], replayBody: prefix, replayWireBytes: 5_000_000
        )
        #expect(diff.bodyComparisonPartial == true)
        #expect(diff.isIdentical == false)
        // Prefixes match and the wire sizes agree, so no positive change is asserted
        // either — the partial flag is what carries the uncertainty.
        #expect(diff.bodyChanged == false)
        // Sizes report the transfer, not the clipped artifact.
        #expect(diff.bodyBytesFrom == 5_000_000)
        #expect(diff.bodyBytesTo == 5_000_000)
    }

    /// Differing wire sizes are still a difference we can assert, even from prefixes.
    @Test func cappedBodiesWithDifferingWireSizesReportAChange() async {
        let prefix = Data(repeating: 0x41, count: 1024)
        let diff = NetworkReplayDiff.between(
            sourceStatus: 200, sourceHeaders: [:], sourceBody: prefix, sourceWireBytes: 5_000_000,
            replayStatus: 200, replayHeaders: [:], replayBody: prefix, replayWireBytes: 9_000_000
        )
        #expect(diff.bodyChanged)
        #expect(diff.bodyComparisonPartial == true)
        #expect(diff.isIdentical == false)
    }

    /// Only one side clipped: the comparison is still partial, and the uncapped side
    /// keeps reporting its real recorded size.
    @Test func oneSidedCapMarksTheComparisonPartial() async {
        let diff = NetworkReplayDiff.between(
            sourceStatus: 200, sourceHeaders: [:], sourceBody: Data(repeating: 0x41, count: 1024),
            sourceWireBytes: 5_000_000,
            replayStatus: 200, replayHeaders: [:], replayBody: Data("small".utf8)
        )
        #expect(diff.bodyComparisonPartial == true)
        #expect(diff.bodyBytesFrom == 5_000_000)
        #expect(diff.bodyBytesTo == 5)
        #expect(diff.bodyChanged)
    }

    @Test func replayRequestBodyInputsAreMutuallyExclusive() async throws {
        #expect(throws: NetworkReplayError.self) {
            _ = try NetworkReplayRequest(body: "x", clearBody: true).resolvedBody()
        }
        // keep (no inputs) -> nil; clear -> .some(nil); replace -> .some(data)
        let keep = try NetworkReplayRequest().resolvedBody()
        #expect(keep == nil)
        let cleared = try NetworkReplayRequest(clearBody: true).resolvedBody()
        #expect(cleared == .some(nil))
        let replaced = try NetworkReplayRequest(body: "hi").resolvedBody()
        #expect(replaced == .some(Data("hi".utf8)))
    }
}
