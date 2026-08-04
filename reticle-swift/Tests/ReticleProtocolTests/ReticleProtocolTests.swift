import XCTest
@testable import ReticleProtocol

final class PortMapTests: XCTestCase {
    // Ground-truth values computed from the FNV-1a spec (same algorithm the
    // Kotlin PortMap uses). If these drift, the host and agent would forward to
    // different ports and never connect.
    func testDerivePortMatchesSpec() {
        XCTAssertEqual(PortMap.derivePort(""), 8765)
        XCTAssertEqual(PortMap.derivePort("   "), 8765)
        XCTAssertEqual(PortMap.derivePort("com.example.app"), 8840)
        XCTAssertEqual(PortMap.derivePort("dev.reticle.sample"), 9763)
        XCTAssertEqual(PortMap.derivePort("com.apple.mobilesafari"), 8817)
        XCTAssertEqual(PortMap.derivePort("reticle.ios.demo"), 9162)
    }

    func testFnvHashVectors() {
        XCTAssertEqual(PortMap.fnv1a32(""), 0x811C9DC5)
        XCTAssertEqual(PortMap.fnv1a32("com.example.app"), 0x7E6D8A6B)
        XCTAssertEqual(PortMap.fnv1a32("dev.reticle.sample"), 0xAEFFFCDE)
    }
}

final class GoldenFixtureTests: XCTestCase {
    /// The Swift models must decode the same golden fixture the Kotlin contract
    /// test validates, so both implementations of `reticle-protocol` agree on the
    /// exact iOS wire bytes.
    func testDecodesSharedIosGolden() throws {
        // <repo>/reticle-swift/Tests/ReticleProtocolTests/<this file>
        let here = URL(fileURLWithPath: #filePath)
        let repoRoot = here.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repoRoot.appendingPathComponent("reticle-protocol/fixtures/ios-snapshot.golden.json")
        let data = try Data(contentsOf: fixture)
        let snap = try ReticleJSON.decode(Snapshot.self, from: data)
        XCTAssertEqual(snap.platform, "ios")
        XCTAssertEqual(snap.schemaVersion, 1)
        XCTAssertEqual(snap.nodes["r3"]?.kind, .axElement)
        XCTAssertEqual(snap.nodes["r2"]?.testId, "checkout.payButton")
        // Re-encoding then decoding is lossless.
        let reencoded = try ReticleJSON.encodeWire(snap)
        let again = try ReticleJSON.decode(Snapshot.self, from: reencoded)
        XCTAssertEqual(again.nodes.count, snap.nodes.count)
        XCTAssertEqual(again.nodes["r3"]?.custom["swiftUIOrigin"], .text("host"))
    }
}

final class JSONShapeTests: XCTestCase {
    private func sampleSnapshot() -> Snapshot {
        let root = Node(ref: "r0", kind: .application, typeName: "UIApplication", role: "application", children: ["r1"])
        let window = Node(ref: "r1", parentRef: "r0", kind: .window, typeName: "UIWindow", role: "window",
                          frame: Rect(x: 0, y: 0, width: 393, height: 852), children: ["r2", "r3"])
        let button = Node(ref: "r2", parentRef: "r1", kind: .view, typeName: "UIButton", role: "button",
                          contentDescription: "Continue", text: "Continue", testId: "checkout.payButton",
                          frame: Rect(x: 24, y: 720, width: 345, height: 50), isInteractive: true,
                          custom: ["alpha": .real(1.0), "backgroundColor": .text("#FF007AFF")])
        let swiftui = Node(ref: "r3", parentRef: "r1", kind: .axElement, typeName: "SwiftUI.Button", role: "button",
                           contentDescription: "Sign In", text: "Sign In", testId: "login.signIn",
                           frame: Rect(x: 24, y: 640, width: 345, height: 44), isInteractive: true,
                           custom: ["observationBackend": .text("native-accessibility")])
        return Snapshot(
            capturedAtMillis: 1719400000000,
            platform: "ios",
            screen: ScreenInfo(size: Size(width: 393, height: 852), density: 3.0, interfaceStyle: "dark"),
            rootRef: "r0",
            nodes: ["r0": root, "r1": window, "r2": button, "r3": swiftui]
        )
    }

    func testOmitDefaultsRoundTrip() throws {
        let snap = sampleSnapshot()
        let data = try ReticleJSON.encodeWire(snap)
        let json = String(decoding: data, as: UTF8.self)
        // schemaVersion and platform are always emitted.
        XCTAssertTrue(json.contains("\"schemaVersion\":1"))
        XCTAssertTrue(json.contains("\"platform\":\"ios\""))
        // Default booleans/collections are omitted: r2 has isVisible=true (omitted),
        // isEnabled=true (omitted), regions=[] (omitted).
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let nodes = obj["nodes"] as! [String: Any]
        let r2 = nodes["r2"] as! [String: Any]
        XCTAssertNil(r2["isVisible"], "default true isVisible must be omitted")
        XCTAssertNil(r2["isEnabled"], "default true isEnabled must be omitted")
        XCTAssertNil(r2["regions"], "empty regions must be omitted")
        XCTAssertEqual(r2["isInteractive"] as? Bool, true, "non-default isInteractive must be emitted")

        // Decode back and confirm defaults are restored losslessly.
        let decoded = try ReticleJSON.decode(Snapshot.self, from: data)
        XCTAssertEqual(decoded.platform, "ios")
        XCTAssertEqual(decoded.nodes["r2"]?.isVisible, true)
        XCTAssertEqual(decoded.nodes["r2"]?.isEnabled, true)
        XCTAssertEqual(decoded.nodes["r2"]?.custom["alpha"], .real(1.0))
        XCTAssertEqual(decoded.nodes["r3"]?.kind, .axElement)
    }

    func testKeyboardOcclusionMatchesKotlinDerivation() throws {
        // Mirrors reticle-core's SnapshotDerivationsTest: an item whose tap
        // point is under the visible keyboard is marked occluded-by:keyboard;
        // items above it are untouched. Keyboard state round-trips the wire.
        var snap = sampleSnapshot()
        snap.screen.keyboard = KeyboardInfo(visible: true, frame: Rect(x: 0, y: 700, width: 393, height: 152))
        let compact = CompactObservation.from(snap)
        let pay = compact.items.first { $0.ref == "r2" }! // y-center 745 -> covered
        XCTAssertEqual(pay.occludedBy, CompactObservation.occluderKeyboard)
        XCTAssertTrue(pay.line().contains("occluded-by:keyboard"), pay.line())
        let signIn = compact.items.first { $0.ref == "r3" }! // y-center 662 -> clear
        XCTAssertNil(signIn.occludedBy)

        let data = try ReticleJSON.encodeWire(snap)
        let decoded = try ReticleJSON.decode(Snapshot.self, from: data)
        XCTAssertEqual(decoded.screen.keyboard?.visible, true)
        XCTAssertEqual(decoded.screen.keyboard?.frame?.y, 700)
    }

    /// The Swift half of reticle-core's
    /// `compact_doesNotTreatALingeringKeyboardHostAsCover`. Measured on the iOS login
    /// screen: after `act hide-keyboard` reported `keyboardVisible=0`, the submit
    /// button still read `occluded-by:<the keyboard's host window>` — iOS keeps that
    /// window and its input view in the hierarchy, still over what the keys covered.
    func testALingeringKeyboardHostIsNotCover() throws {
        var snap = sampleSnapshot()
        snap.screen.keyboard = KeyboardInfo(visible: false, frame: nil)
        snap.nodes["kbHost"] = Node(
            ref: "kbHost", parentRef: snap.rootRef, kind: .view, typeName: "UITextEffectsWindow",
            role: "window", frame: Rect(x: 0, y: 0, width: 393, height: 852),
            isInteractive: true, custom: ["keyboardHost": .bool(true)], children: ["kbInput"]
        )
        snap.nodes["kbInput"] = Node(
            ref: "kbInput", parentRef: "kbHost", kind: .view, typeName: "UIInputSetHostView",
            role: "view", frame: Rect(x: 0, y: 700, width: 393, height: 152), isInteractive: true
        )
        snap.nodes[snap.rootRef]?.children.append("kbHost")

        let compact = CompactObservation.from(snap)
        let pay = compact.items.first { $0.ref == "r2" }!  // y-center 745, under the lingering input view
        XCTAssertNil(pay.occludedBy, "a dismissed keyboard's host must not read as cover: \(pay.line())")
    }

    /// The Swift half of reticle-core's `CompactCollapseTest`. The two folds must
    /// agree node for node, or the same picker reads differently on each platform.
    func testFoldsAnonymousLayersLikeKotlin() throws {
        // One UIPickerView row as UIKit builds it: cell > (label, contentView).
        // Two anonymous rectangles at one place; only the label can be named.
        func node(_ ref: String, _ parent: String?, _ type: String, _ role: String,
                  _ frame: Rect, text: String? = nil, interactive: Bool = false,
                  children: [String] = []) -> Node {
            Node(ref: ref, parentRef: parent, kind: .view, typeName: type, role: role,
                 text: text, frame: frame, isInteractive: interactive, children: children)
        }
        let root = Node(ref: "root", kind: .application, typeName: "UIApplication", children: ["cell"])
        let snap = Snapshot(
            capturedAtMillis: 0, platform: "ios",
            screen: ScreenInfo(size: Size(width: 400, height: 900), density: 3),
            rootRef: "root",
            nodes: [
                "root": root,
                "cell": node("cell", "root", "UIPickerTableViewTitledCell", "container",
                             Rect(x: 41, y: 487, width: 165, height: 24),
                             interactive: true, children: ["label", "content"]),
                "label": node("label", "cell", "UILabel", "text",
                              Rect(x: 50, y: 487, width: 147, height: 24), text: "09"),
                "content": node("content", "cell", "UITableViewCellContentView", "view",
                                Rect(x: 41, y: 487, width: 165, height: 24), interactive: true),
            ]
        )
        let compact = CompactObservation.from(snap)
        XCTAssertEqual(compact.items.map { $0.ref }, ["label"])
        XCTAssertEqual(compact.collapsedWrappers, 2)
        // The survivor absorbs the tappability, or the row reads inert.
        XCTAssertTrue(compact.items[0].isInteractive, compact.items[0].line())
        // And the fold is stated, not silent.
        XCTAssertTrue(Render.compact(snap).contains("2 anonymous layer(s) folded"), Render.compact(snap))
    }

    /// A payload from an agent that folded nothing — or predates folding — has no
    /// `collapsedWrappers` key at all, because reticle-core omits defaults.
    func testCollapsedWrappersDefaultsWhenAbsentFromTheWire() throws {
        let json = #"{"capturedAtMillis":1,"screen":{"size":{"width":1,"height":1},"density":1},"items":[]}"#
        let decoded = try ReticleJSON.decode(CompactObservation.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.collapsedWrappers, 0)
        // ...and it stays absent on the way back out.
        let out = String(decoding: try ReticleJSON.encodeWire(decoded), as: UTF8.self)
        XCTAssertFalse(out.contains("collapsedWrappers"), out)
    }

    func testMetadataValueDiscriminator() throws {
        let data = try ReticleJSON.encodeWire(MetadataValue.integer(42))
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"_type\":\"int\""))
        XCTAssertTrue(json.contains("\"value\":42"))
        let decoded = try ReticleJSON.decode(MetadataValue.self, from: data)
        XCTAssertEqual(decoded, .integer(42))
    }

    func testDerivationsAndRender() throws {
        let snap = sampleSnapshot()
        let semantics = SemanticTree.build(from: snap)
        // The application/window nodes carry no targeting signal and are dropped;
        // both buttons are kept.
        XCTAssertNotNil(semantics.findByTestId("checkout.payButton"))
        XCTAssertNotNil(semantics.findByTestId("login.signIn"))

        let compact = CompactObservation.from(snap)
        XCTAssertEqual(compact.items.count, 2)
        XCTAssertTrue(compact.items.first!.line().contains("#checkout.payButton"))

        let tree = try Render.view("tree", snapshot: snap)
        XCTAssertTrue(tree.contains("#checkout.payButton"))
        XCTAssertTrue(tree.contains("#login.signIn"))
        XCTAssertTrue(tree.contains("window"))
        let node = try Render.view("node", snapshot: snap, selector: Selector(testId: "login.signIn"))
        XCTAssertTrue(node.contains("SwiftUI.Button"))
        XCTAssertTrue(node.contains("axElement"))
    }
}
