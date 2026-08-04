import Foundation
import Testing

@testable import ReticleHostCore
@testable import ReticleHostIos
import ReticleProtocol

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

/// `--clear` on iOS re-read the field by REF after deleting, and a ref is a
/// traversal index. Measured on the login screen: emptying the field brought the
/// keyboard's accessory views into the hierarchy (71 nodes -> 100), `r14` stopped
/// being the text field, and the read-back compared the field's old value against a
/// status LABEL — `was "0123456": "Enter the code"` — so a clear that had worked was
/// refused. The Android helper has always re-found by identity (`TypeReadback.refind`).
@Suite("iOS field re-find")
struct IosRefindTests {

    private func field(_ ref: String, _ id: String?, _ y: Double, text: String?, focused: Bool = false) -> Node {
        Node(
            ref: ref, parentRef: "root", kind: .view, typeName: "UITextField", role: "textField",
            text: text, testId: id, frame: Rect(x: 24, y: y, width: 354, height: 34),
            isInteractive: true, isFocused: focused
        )
    }

    private func snapshot(_ nodes: [Node]) -> Snapshot {
        var map: [String: Node] = [
            "root": Node(ref: "root", kind: .application, typeName: "UIApplication",
                         children: nodes.map(\.ref))
        ]
        for node in nodes { map[node.ref] = node }
        return Snapshot(
            capturedAtMillis: 0, platform: "ios",
            screen: ScreenInfo(size: Size(width: 402, height: 874), density: 3),
            rootRef: "root", nodes: map
        )
    }

    @Test func theSameRefPointingAtAnotherNodeIsNotTheField() {
        let before = field("r14", "login.codeField", 240, text: "0123456", focused: true)
        // The renumbered tree: r14 is now the status label, and the field is r22.
        let after = snapshot([
            Node(ref: "r14", parentRef: "root", kind: .view, typeName: "UILabel", role: "text",
                 text: "Enter the code", frame: Rect(x: 24, y: 192, width: 354, height: 24)),
            field("r22", "login.codeField", 240, text: "", focused: true),
        ])
        #expect(IosHelperClient.refind(before, in: after)?.ref == "r22")
    }

    @Test func withNoIdTheFocusedFieldWins() {
        let before = field("r14", nil, 240, text: "abc", focused: true)
        let after = snapshot([
            field("r9", nil, 600, text: "other"),
            field("r30", nil, 240, text: "", focused: true),
        ])
        #expect(IosHelperClient.refind(before, in: after)?.ref == "r30")
    }

    @Test func withNoIdAndNoFocusThePositionIsTheLastResort() {
        let before = field("r14", nil, 240, text: "abc")
        let after = snapshot([
            field("r9", nil, 600, text: "other"),
            field("r31", nil, 240, text: ""),
        ])
        #expect(IosHelperClient.refind(before, in: after)?.ref == "r31")
    }
}
