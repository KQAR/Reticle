import Foundation
import Testing
@testable import ReticleHostCore

@Suite("Args numeric options")
struct ArgsIntOptionTests {
    @Test func absentOptionIsNil() async throws {
        let args = Args(["ui", "tree"])
        #expect(try args.intOption("depth") == nil)
    }

    @Test func validIntegerParses() async throws {
        let args = Args(["ui", "tree", "--depth", "3"])
        #expect(try args.intOption("depth") == 3)
    }

    @Test func nonNumericValueThrowsNamingTheFlagAndValue() async {
        // `--depth x` used to fall back to 0 and render an empty tree; the
        // error must say which flag and which value so the caller can fix it.
        let args = Args(["ui", "tree", "--depth", "x"])
        #expect {
            try args.intOption("depth")
        } throws: { error in
            "\(error)".contains("--depth") && "\(error)".contains("'x'")
        }
    }

    @Test func bareFlagWithoutAValueThrows() async {
        // A bare `--proxy-port` parses as "true"; it used to silently become
        // the default port instead of asking for a value.
        let args = Args(["serve", "--proxy-port"])
        #expect(throws: (any Error).self) { try args.intOption("proxy-port") }
    }
}

@Suite("ServeOptions numeric flags")
struct ServeOptionsParsingTests {
    @Test func badProxyPortFailsLoudlyInsteadOfDefaulting() async {
        #expect {
            try ServeOptions(args: Args(["serve", "--proxy-port", "abc"]))
        } throws: { error in
            "\(error)".contains("--proxy-port")
        }
    }

    @Test func validNumericFlagsStillParse() async throws {
        let options = try ServeOptions(args: Args([
            "serve", "--port", "9999", "--proxy-port", "9091", "--event-limit", "50",
        ]))
        #expect(options.port == 9999)
        #expect(options.proxyPort == 9091)
        #expect(options.eventLimit == 50)
    }
}
