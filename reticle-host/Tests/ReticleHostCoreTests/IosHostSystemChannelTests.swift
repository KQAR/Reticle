import Testing
@testable import ReticleHostIos
import ReticleHostShared
import ReticleProtocol

/// The rules for reading `reticle-device tree`, pinned against the three shapes a
/// real device (iOS 27.0.1) was measured to report.
@Suite("host system channel tree")
struct IosHostSystemChannelTests {

    private func node(_ type: Int, _ label: String? = nil, children: [String] = [],
                      frame: [Double] = [0, 0, 10, 10], id: String? = nil, value: String? = nil) -> [String: Any] {
        var n: [String: Any] = ["elementType": type, "children": children, "frame": frame, "enabled": true]
        if let label { n["label"] = label }
        if let id { n["identifier"] = id }
        if let value { n["value"] = value }
        return n
    }

    private func tree(bundle: String?, root: [String: Any], _ rest: [String: [String: Any]]) throws -> HostAXTree {
        var app: [String: Any] = ["id": "1", "pid": 42]
        if let bundle { app["bundleId"] = bundle }
        var nodes = rest
        nodes["1"] = root
        return try HostAXTree.decode(["apps": [app], "nodes": nodes])
    }

    /// A system modal: SpringBoard in front holding only the modal's texts and
    /// buttons. The device reports no alert element at all.
    private func alertUp() throws -> HostAXTree {
        try tree(bundle: "com.apple.springboard",
                 root: node(1, " ", children: ["2", "3", "4"], frame: [0, 0, 428, 926]),
                 ["2": node(48, "Title"),
                  "3": node(9, "Later", frame: [70, 491, 140, 48]),
                  "4": node(9, "Allow", frame: [218, 491, 140, 48])])
    }

    @Test func springBoardWithoutIconsIsAnOverlay() throws {
        let t = try alertUp()
        #expect(t.overlayIsUp)
        let obs = t.overlay()
        #expect(obs.overlayPresent)
        #expect(obs.sourceChannel == "system-host")
        #expect(obs.targetProcess == "com.apple.springboard")
        // A blank root label is no label, not a " " label.
        #expect(obs.nodes["s1"]?.label == nil)
        #expect(obs.nodes["s3"]?.parentRef == "s1")
        #expect(obs.nodes["s1"]?.children == ["s2", "s3", "s4"])
        #expect(t.frontButtons().compactMap(\.label) == ["Later", "Allow"])
    }

    @Test func theHomeScreenIsNotAnOverlay() throws {
        let t = try tree(bundle: "com.apple.springboard",
                         root: node(1, children: ["2"], frame: [0, 0, 428, 926]),
                         ["2": node(HostAXTree.iconType, "Settings")])
        #expect(!t.overlayIsUp)
        #expect(t.overlay().overlayPresent == false)
        #expect(try t.front(named: "com.apple.springboard").nodes.count == 2)
    }

    @Test func anAppInFrontIsReadByNameAndRefusedUnderAnyOther() throws {
        let t = try tree(bundle: "dev.reticle.sampleios",
                         root: node(1, "SampleApp", children: ["2"], frame: [0, 0, 428, 926]),
                         ["2": node(49, children: [], id: "swiftui.nickname", value: "abc")])
        #expect(!t.overlayIsUp)
        let obs = try t.front(named: "dev.reticle.sampleios")
        #expect(obs.nodes["s2"]?.testId == "swiftui.nickname")
        #expect(obs.nodes["s2"]?.value == "abc")
        #expect(obs.nodes["s2"]?.role == .textField)
        do {
            _ = try t.front(named: "com.apple.springboard")
            Issue.record("a target that is not in front must be refused, not answered empty")
        } catch let e as HelperError {
            #expect(e.message.contains("dev.reticle.sampleios is"))
        }
    }

    // This channel has no hit test; a constant `false` must say so.
    @Test func hittabilityIsDeclaredUnreadable() throws {
        let n = try alertUp().overlay().nodes["s3"]
        #expect(n?.isHittable == false)
        #expect(n?.unreadable["isHittable"] != nil)
        #expect(n?.unreadable["isVisible"] != nil)
    }

    @Test func aTapChangesTheSignatureOnlyWhenTheScreenChanged() throws {
        let a = try alertUp(), b = try alertUp()
        #expect(a.signature == b.signature)
        let home = try tree(bundle: "com.apple.springboard",
                            root: node(1, children: ["2"]), ["2": node(HostAXTree.iconType, "Settings")])
        #expect(a.signature != home.signature)
    }

    @Test func pointsNormalizeToTheDigitizerRangeAndOffScreenIsRefused() throws {
        let screen = try alertUp().screenSize!
        #expect(screen.width == 428 && screen.height == 926)
        #expect(HostAXTree.normalize(x: 0, y: 0, screen: screen)! == (0, 0))
        #expect(HostAXTree.normalize(x: 428, y: 926, screen: screen)! == (65535, 65535))
        #expect(HostAXTree.normalize(x: 214, y: 463, screen: screen)! == (32768, 32768))
        #expect(HostAXTree.normalize(x: 429, y: 10, screen: screen) == nil)
        #expect(HostAXTree.normalize(x: -1, y: 10, screen: screen) == nil)
    }

    @Test func aTreeThatNamesNoApplicationIsAnError() {
        #expect(throws: HelperError.self) {
            try HostAXTree.decode(["apps": [], "nodes": [:] as [String: Any]])
        }
    }
}
