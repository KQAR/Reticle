import Foundation
import Testing
import ReticleProtocol

/// Pins `TypeReadback.classify` against the fixture the Kotlin
/// `TypeReadbackTest` reads too: reticle-protocol/fixtures/type-readback.cases.json.
@Suite("type read-back classification")
struct TypeReadbackTests {
    private struct Case: Decodable {
        struct Expect: Decodable { var landed: String; var landedChars: Int; var loss: Bool }
        var name: String; var before: String; var after: String; var typed: String; var expect: Expect
    }
    private struct Cases: Decodable { var cases: [Case] }

    @Test func everyFixtureCaseClassifiesAsSpecified() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("reticle-protocol/fixtures/type-readback.cases.json"))
        let cases = try JSONDecoder().decode(Cases.self, from: data).cases
        #expect(!cases.isEmpty)
        for c in cases {
            let v = TypeReadback.classify(before: c.before, after: c.after, typed: c.typed)
            #expect(v.landed.rawValue == c.expect.landed, "\(c.name)")
            #expect(v.landedChars == c.expect.landedChars, "\(c.name)")
            #expect(TypeReadback.isLoss(v.landed) == c.expect.loss, "\(c.name)")
        }
    }
}
