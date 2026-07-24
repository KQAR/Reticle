import Foundation
import Testing
@testable import ReticleNetworkLane

/// The replay diff is the evidence Reticle emits for the capture → modify → replay
/// → diff loop, so its comparison logic is pinned here without a live proxy.
@Suite("Network replay diff")
struct NetworkReplayDiffTests {
    @Test func identicalResponsesReportNoChange() {
        let diff = NetworkReplayDiff.between(
            sourceStatus: 200, sourceHeaders: ["Content-Type": "application/json"], sourceBody: Data("{}".utf8),
            replayStatus: 200, replayHeaders: ["content-type": "application/json"], replayBody: Data("{}".utf8)
        )
        #expect(diff.isIdentical)
        #expect(diff.statusChanged == false)
        #expect(diff.bodyChanged == false)
        #expect(diff.headersChanged.isEmpty)
    }

    @Test func statusAndBodyChangesAreDetected() {
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

    @Test func headerDeltasAreNameOnlyAndCaseInsensitive() {
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

    @Test func replayRequestBodyInputsAreMutuallyExclusive() throws {
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
