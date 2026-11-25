import Foundation
import Testing
@testable import ReticleHostCore

/// The guide's topics are reachable both ways, and the stub points at the guide.
///
/// `.embedInCode` gives no way to enumerate what it embedded, so `ReticleSkill.topics`
/// is a hand-written table — and a topic file the table misses, or a
/// `reticle skill show <x>` in the guide that the table cannot answer, is silent
/// until an agent hits it. SKILL.md is what an agent reads every time; a topic it
/// never names is one no agent will ever open.
@Suite("the embedded skill guide")
struct SkillGuideTests {
    private var referencesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ReticleHostCore/SkillGuide/references")
    }

    @Test func everyTopicFileIsInTheTable() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: referencesDir.path)
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }
        #expect(!files.isEmpty)
        #expect(Set(files) == Set(ReticleSkill.topics.keys))
    }

    @Test func theGuideNamesEveryTopicAndOnlyRealOnes() throws {
        let regex = try NSRegularExpression(pattern: #"reticle skill show ([a-z0-9-]+)"#)
        let guide = ReticleSkill.guide
        let named = Set(regex.matches(in: guide, range: NSRange(guide.startIndex..., in: guide)).map {
            String(guide[Range($0.range(at: 1), in: guide)!])
        })
        #expect(named.subtracting(ReticleSkill.topics.keys).isEmpty, "guide names missing topics: \(named.subtracting(ReticleSkill.topics.keys))")
        #expect(Set(ReticleSkill.topics.keys).subtracting(named).isEmpty, "topics no row points at: \(Set(ReticleSkill.topics.keys).subtracting(named))")
    }

    @Test func theStubCarriesTheGuidesNameAndDescription() {
        let stub = ReticleSkill.stub
        #expect(stub.hasPrefix("---\nname: reticle\ndescription:"))
        #expect(stub.contains("reticle-stub: \"\(ReticleSkill.stubVersion)\""))
        #expect(stub.contains("`reticle skill show`"))
        #expect(!ReticleSkill.frontmatter.body.contains("name: reticle\ndescription:"))
    }

    @Test func versionOrdering() {
        #expect(ReticleInstall.isNewer("0.23.0", than: "0.22.0"))
        #expect(ReticleInstall.isNewer("0.22.10", than: "0.22.9"))
        #expect(ReticleInstall.isNewer("1.0.0", than: "0.99.99"))
        #expect(!ReticleInstall.isNewer("0.22.0", than: "0.22.0"))
        #expect(!ReticleInstall.isNewer("0.21.5", than: "0.22.0"))
    }
}
