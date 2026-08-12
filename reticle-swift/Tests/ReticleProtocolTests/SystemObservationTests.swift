import Testing
@testable import ReticleProtocol

@Suite("system channel observation types")
struct SystemObservationTests {

    // TC-030: an element type the mapping does not cover must survive as an
    // explicitly unrecognized role carrying its raw value. Dropping the node would
    // delete something that is really on screen; folding it into `other` would
    // state a role the platform never claimed.
    @Test func unknownElementTypeBecomesUnrecognizedAndKeepsRawValue() {
        let role = SystemRole.fromElementType(9999)
        #expect(role == .unrecognized(rawValue: 9999))
        #expect(role.wireName == "unrecognized:9999")
        // Specifically NOT collapsed into a known role.
        #expect(role != .other)
        #expect(role != .button)
    }

    @Test func knownElementTypesMapToNamedRoles() {
        #expect(SystemRole.fromElementType(9) == .button)
        #expect(SystemRole.fromElementType(48) == .staticText)
        #expect(SystemRole.fromElementType(49) == .textField)
        #expect(SystemRole.fromElementType(50) == .secureTextField)
        #expect(SystemRole.fromElementType(58) == .webView)
        #expect(SystemRole.fromElementType(42) == .link)
        // A system-owned modal arrives as sheet/alert/dialog depending on version
        // and kind; all three must read as a modal. 7 is what a real permission
        // prompt was measured to be on iOS 26.
        #expect(SystemRole.fromElementType(7) == .alert)
        #expect(SystemRole.fromElementType(5) == .alert)
        #expect(SystemRole.fromElementType(8) == .alert)
    }

    @Test func unrecognizedRoleSurvivesARoundTrip() throws {
        // The raw value has to make it across the wire, otherwise a future iOS
        // element type is undiagnosable from the host side. Wrapped in a node
        // rather than encoded bare, so the test does not rest on top-level JSON
        // fragment support.
        let node = SystemNode(
            ref: "n1", role: .unrecognized(rawValue: 71), isEnabled: true, isHittable: true
        )
        let decoded = try ReticleJSON.decode(
            SystemNode.self, from: try ReticleJSON.encodeWire(node)
        )
        #expect(decoded.role == .unrecognized(rawValue: 71))
    }

    @Test func unknownRoleSpellingDegradesInsteadOfFailingTheDecode() throws {
        // A newer runner talking to an older host must not take the whole
        // observation down with it.
        let json = """
        {"ref":"n1","children":[],"role":"someRoleFromTheFuture","isEnabled":true,"isHittable":true,"unreadable":{}}
        """
        let decoded = try ReticleJSON.decode(SystemNode.self, from: json)
        guard case .unrecognized = decoded.role else {
            Issue.record("expected an unrecognized role, got \(decoded.role)")
            return
        }
    }

    // The channel-wide gaps are the mechanism NFR-003 rests on: a property this
    // channel cannot read must name itself rather than arrive empty.
    @Test func channelGapsNameEveryPropertyThisChannelCannotRead() {
        let gaps = SystemNode.channelGaps
        for key in ["isVisible", "typeName", "checked", "expanded",
                    "isFocusable", "isFocused", "regions", "style", "domNode"] {
            #expect(gaps[key] != nil, "\(key) must be declared unreadable, not left absent")
            #expect(!(gaps[key] ?? "").isEmpty, "\(key) needs a stated reason")
        }
    }

    @Test func aNodeCarriesTheChannelGapsByDefault() {
        let node = SystemNode(ref: "n1", role: .button, isEnabled: true, isHittable: true)
        // `isVisible` is the one most likely to be mistaken for present-and-false,
        // so it is the one worth pinning.
        #expect(node.unreadable["isVisible"] != nil)
    }

    // TC-010's contract at the type level: "nothing is covering the app" is a
    // positive answer, distinguishable from "I read nothing".
    @Test func absenceOfAnOverlayIsStatedRatherThanImplied() {
        let empty = SystemObservation(overlayPresent: false)
        #expect(empty.overlayPresent == false)
        #expect(empty.rootRef == nil)
        #expect(empty.nodes.isEmpty)
        // Source is always stamped, so this can never be mistaken for an agent read.
        #expect(empty.sourceChannel == SystemObservation.channelName)
    }

    @Test func truncationCarriesBothWhatCameBackAndTheCeiling() {
        let obs = SystemObservation(
            rootRef: "n1",
            nodes: ["n1": SystemNode(ref: "n1", role: .window, isEnabled: true, isHittable: true)],
            overlayPresent: true,
            truncation: SystemTruncation(returned: 200, limit: 200, reason: "node-limit")
        )
        // Both numbers matter: "truncated" alone does not tell a caller whether to
        // narrow the target or abandon it.
        #expect(obs.truncation?.returned == 200)
        #expect(obs.truncation?.limit == 200)
        #expect(obs.truncation?.reason == "node-limit")
    }

    @Test func restartFlagDefaultsToFalseAndSurvivesEncoding() throws {
        let obs = SystemObservation(overlayPresent: true, runnerRestarted: true)
        #expect(SystemObservation(overlayPresent: true).runnerRestarted == false)
        let decoded = try ReticleJSON.decode(
            SystemObservation.self, from: try ReticleJSON.encodeWire(obs)
        )
        // A restart interrupts the foreground, so the fact must survive transport.
        #expect(decoded.runnerRestarted)
    }

    @Test func readTargetsDescribeThemselvesForEvidence() {
        #expect(SystemReadTarget.topmostOverlay.describe == "topmost-overlay")
        #expect(SystemReadTarget.home.describe == "home")
        #expect(SystemReadTarget.app(bundleId: "com.example.app").describe == "app:com.example.app")
    }
}
