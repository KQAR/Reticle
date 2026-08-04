import Foundation
import Testing

@testable import ReticleHostCore

/// A flag a command does not read used to be dropped in silence, so the command
/// ran as if it had never been passed. The measured case is the first test.
@Suite("Unknown CLI flags")
struct CliFlagsTests {

    @Test func aFlagThatBelongsToAnotherGestureIsReportedByName() {
        // `act tap --text "Tak"` answered "could not resolve selector '<empty>'",
        // which reads as an empty selector rather than a misplaced flag.
        let args = Args(["act", "tap", "--package", "com.x", "--text", "Tak"])
        #expect {
            try CliFlags.validate(args, command: "act", subcommand: "tap")
        } throws: { error in
            let message = "\(error)"
            return message.contains("unknown option --text")
                && message.contains("`act tap`")
                // The other half of the answer: where the flag DOES belong.
                && message.contains("act type")
                && message.contains("act wait")
        }
    }

    @Test func everyFlagAGestureReallyReadsIsAccepted() throws {
        // The guard against the fix being worse than the gap: a false "unknown
        // option" REJECTS a call that used to work.
        try CliFlags.validate(
            Args([
                "act", "type", "--package", "com.x", "--test-id", "field", "--text", "abc",
                "--clear", "--submit", "--type-delay", "40", "--verify", "field",
                "--trace-output", "/tmp/t", "--settle-timeout", "800", "--json",
                "--serial", "emulator-5554",
            ]),
            command: "act", subcommand: "type"
        )
        try CliFlags.validate(
            Args(["act", "wait", "--package", "com.x", "--for", "field", "--text", "ok", "--strict"]),
            command: "act", subcommand: "wait"
        )
        try CliFlags.validate(
            Args(["ui", "compact", "--live", "--package", "com.x", "--window", "top"]),
            command: "ui", subcommand: "compact"
        )
        try CliFlags.validate(
            Args(["app", "inject", "--package", "com.x", "--restart-under-debugger"]),
            command: "app", subcommand: "inject"
        )
    }

    @Test func aTypoIsReportedEvenThoughNoCommandTakesIt() {
        let args = Args(["ui", "compact", "--live", "--package", "com.x", "--windwo", "top"])
        #expect {
            try CliFlags.validate(args, command: "ui", subcommand: "compact")
        } throws: { error in
            "\(error)".contains("unknown option --windwo") && "\(error)".contains("--window")
        }
    }

    @Test func anUnvalidatedCommandFamilyIsLeftAlone() throws {
        // `rule` / `replay` / `trace` have no table: guessing one would reject calls
        // that work today, which is worse than the papercut this fixes.
        #expect(CliFlags.accepted(command: "rule", subcommand: "set") == nil)
        try CliFlags.validate(
            Args(["rule", "set", "--match", "x", "--status", "500"]),
            command: "rule", subcommand: "set"
        )
        // Same for a subcommand that does not exist: the dispatcher's own
        // "unknown ui subcommand" is the right error, not a flag complaint.
        try CliFlags.validate(
            Args(["ui", "nope", "--whatever", "1"]), command: "ui", subcommand: "nope"
        )
    }

    @Test func globalFlagsAreAcceptedEverywhere() throws {
        try CliFlags.validate(
            Args(["status", "--package", "com.x", "--serial", "abc", "--json", "--target", "ios"]),
            command: "status", subcommand: nil
        )
    }
}
