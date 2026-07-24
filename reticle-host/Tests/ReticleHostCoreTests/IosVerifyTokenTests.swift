import Foundation
import Testing
import ReticleProtocol
@testable import ReticleHostCore

/// Pins the iOS `--verify` token grammar to the Android helper's `parseVerifyToken`
/// (guarded there by `VerifyTokenTest`). The two are hand-duplicated across the
/// Kotlin/Swift boundary; this test is the drift guard so the `key=value` spellings
/// (which once silently regressed to never-matching on Android) can't rot on iOS.
@Suite("iOS verify token grammar")
struct IosVerifyTokenTests {
    private let empty = ReticleProtocol.Selector()

    private func parse(_ token: String, act: ReticleProtocol.Selector? = nil) throws -> ReticleProtocol.Selector? {
        try IosHelperClient.parseVerifyToken(token, actSelector: act ?? empty)
    }

    @Test func sigilForms() throws {
        #expect(try parse("#login.status")?.testId == "login.status")
        #expect(try parse("@btn_ok")?.resourceId == "btn_ok")
        #expect(try parse("css=.status")?.cssSelector == ".status")
    }

    @Test func keyEqualsForms() throws {
        #expect(try parse("testId=login.status")?.testId == "login.status")
        #expect(try parse("resourceId=btn_ok")?.resourceId == "btn_ok")
        #expect(try parse("ref=n12")?.ref == "n12")
    }

    @Test func bareTokenIsARef() throws {
        #expect(try parse("n12")?.ref == "n12")
    }

    @Test func falseDisablesVerify() throws {
        #expect(try parse("false") == nil)
    }

    @Test func trueWatchesTheActedSelector() throws {
        let watched = try parse("true", act: ReticleProtocol.Selector(testId: "login.status"))
        #expect(watched?.testId == "login.status")
    }

    @Test func trueWithoutASelectorFailsLoudly() {
        #expect(throws: HelperError.self) {
            _ = try IosHelperClient.parseVerifyToken("true", actSelector: ReticleProtocol.Selector())
        }
    }

    @Test func unknownKeyFailsLoudly() {
        #expect(throws: HelperError.self) {
            _ = try IosHelperClient.parseVerifyToken("bogus=x", actSelector: ReticleProtocol.Selector())
        }
    }
}
