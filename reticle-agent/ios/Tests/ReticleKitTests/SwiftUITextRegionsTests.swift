import XCTest
import ReticleProtocol
@testable import ReticleKit

/// Links inside ONE SwiftUI `Text`, recovered from `accessibilityAttributedLabel`.
///
/// The element is faked here rather than rendered: what the code actually
/// consumes is a public property carrying system-emitted tokens
/// (`UIAccessibilityTokenLink`, `…TokenFontSize`), so a stand-in that carries the
/// same tokens exercises the same path — and does it without a SwiftUI host,
/// which a unit test has no way to build. The end-to-end proof that iOS really
/// emits these tokens lives in the device suite (`scripts/e2e-ios.sh` taps each
/// recovered rect and checks which URL `openURL` received); this pins the
/// reconstruction itself.
@MainActor
final class SwiftUITextRegionsTests: XCTestCase {

    /// An accessibility element whose attributed label carries link + font tokens,
    /// the way iOS builds one for a markdown `Text`.
    private final class FakeElement: NSObject {
        let attributed: NSAttributedString
        init(_ attributed: NSAttributedString) { self.attributed = attributed }
        override var accessibilityAttributedLabel: NSAttributedString? {
            get { attributed }
            set { _ = newValue }
        }
    }

    private static let linkToken = NSAttributedString.Key("UIAccessibilityTokenLink")
    private static let fontSizeToken = NSAttributedString.Key("UIAccessibilityTokenFontSize")

    private func element(_ text: String, links: [String], fontSize: Double = 16) -> FakeElement {
        let attributed = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: attributed.length)
        attributed.addAttribute(Self.fontSizeToken, value: NSNumber(value: fontSize), range: full)
        for link in links {
            let range = (text as NSString).range(of: link)
            attributed.addAttribute(Self.linkToken, value: URL(string: "https://example.com")!, range: range)
        }
        return FakeElement(attributed)
    }

    func testEachLinkRunBecomesASpanRegionInsideTheElementsFrame() throws {
        let text = "I have read and agree to the Terms and the Privacy Policy"
        let frame = Rect(x: 24, y: 620, width: 345, height: 44)
        let result = SwiftUITextRegions.probe(
            element: element(text, links: ["Terms", "Privacy Policy"]),
            screenFrame: frame
        )

        XCTAssertEqual(result.regions.count, 2)
        XCTAssertEqual(Set(result.regions.compactMap { $0.label }), ["Terms", "Privacy Policy"])
        XCTAssertTrue(result.regions.allSatisfy { $0.source == .span })
        for rect in result.regions.flatMap({ $0.rects }) {
            XCTAssertGreaterThanOrEqual(rect.x, frame.x - 1)
            XCTAssertLessThanOrEqual(rect.x + rect.width, frame.x + frame.width + 1)
            XCTAssertGreaterThanOrEqual(rect.y, frame.y - 1)
            XCTAssertGreaterThan(rect.width, 0)
        }
    }

    func testTheTwoLinksDoNotResolveToTheSamePoint() throws {
        // Two regions that agree on a point are worse than none: the tap looks
        // targeted and opens whichever document happens to sit there.
        let text = "Read the Terms and the Privacy Policy"
        let result = SwiftUITextRegions.probe(
            element: element(text, links: ["Terms", "Privacy Policy"]),
            screenFrame: Rect(x: 0, y: 100, width: 360, height: 40)
        )
        let points = result.regions.compactMap { $0.tapPoint() }
        XCTAssertEqual(points.count, 2)
        XCTAssertNotEqual(points[0].x, points[1].x)
    }

    func testTheGridCoversTheWholeLabelSoAnyPhraseStaysTargetable() throws {
        let text = "Read the Terms and the Privacy Policy"
        let result = SwiftUITextRegions.probe(
            element: element(text, links: ["Terms"]),
            screenFrame: Rect(x: 0, y: 100, width: 360, height: 40)
        )
        let grid = try XCTUnwrap(result.charGrid)
        XCTAssertEqual(grid.text, text)
        XCTAssertEqual(grid.lines.first?.start, 0)
        XCTAssertEqual(grid.lines.last?.end, (text as NSString).length)
    }

    func testOrdinaryTextWithNoLinkTokensCostsNothing() {
        // The overwhelmingly common case: no links, so the expensive re-layout
        // must not run and no region may be invented.
        let result = SwiftUITextRegions.probe(
            element: element("Just a label", links: []),
            screenFrame: Rect(x: 0, y: 0, width: 200, height: 20)
        )
        XCTAssertTrue(result.regions.isEmpty)
        XCTAssertNil(result.charGrid)
    }

    func testAnElementWithNoFrameYieldsNothingRatherThanARectAtTheOrigin() {
        let el = element("Read the Terms", links: ["Terms"])
        XCTAssertTrue(SwiftUITextRegions.probe(element: el, screenFrame: nil).regions.isEmpty)
        XCTAssertTrue(
            SwiftUITextRegions.probe(element: el, screenFrame: Rect(x: 0, y: 0, width: 0, height: 20)).regions.isEmpty,
            "a zero-width frame cannot lay text out; guessing would place the rect at 0,0"
        )
    }

    func testAWiderFrameMovesTheSecondLinkRightRatherThanWrapping() throws {
        // Geometry is reconstructed inside the element's own frame, so the frame
        // has to actually drive the layout — a fixed guess would ignore it.
        let text = "Read the Terms and the Privacy Policy"
        func x(of link: String, width: Double) -> Double? {
            SwiftUITextRegions.probe(element: element(text, links: [link]), screenFrame: Rect(x: 0, y: 0, width: width, height: 80))
                .regions.first?.rects.first?.y
        }
        let narrow = try XCTUnwrap(x(of: "Privacy Policy", width: 120))
        let wide = try XCTUnwrap(x(of: "Privacy Policy", width: 360))
        XCTAssertGreaterThan(narrow, wide, "a narrow frame should push the later link onto a lower line")
    }
}
