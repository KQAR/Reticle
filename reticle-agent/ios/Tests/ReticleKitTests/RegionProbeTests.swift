import XCTest
import ReticleProtocol
@testable import ReticleKit

/// The region channels over real UIKit views.
///
/// These are the iOS half of what `scenario.agreements` exercises on a device: a
/// single text node that carries more than one target. The whole point of the
/// probe is that the collapse into one node is recoverable, so the assertions are
/// about which channel fired, what it labelled, and whether the rect it produced
/// is actually inside the text it claims — not about exact pixels, which move
/// with the system font.
@MainActor
final class RegionProbeTests: XCTestCase {

    private var window: UIWindow!

    override func setUp() {
        super.setUp()
        // A real window: the probe converts container -> view -> window -> screen,
        // and a detached view would silently exercise none of that.
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
    }

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private func label(_ configure: (UILabel) -> Void) -> UILabel {
        let label = UILabel(frame: CGRect(x: 20, y: 100, width: 320, height: 80))
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 16)
        configure(label)
        window.addSubview(label)
        window.layoutIfNeeded()
        return label
    }

    /// Every rect a channel emits must sit inside the view that produced it —
    /// the cheap check that catches a coordinate space mixed up somewhere in
    /// container -> view -> window.
    private func assertInside(_ rects: [Rect], _ view: UIView, file: StaticString = #filePath, line: UInt = #line) {
        let frame = view.convert(view.bounds, to: nil)
        XCTAssertFalse(rects.isEmpty, "no rects", file: file, line: line)
        for rect in rects {
            XCTAssertGreaterThanOrEqual(rect.x, frame.minX - 1, "rect left of the view", file: file, line: line)
            XCTAssertLessThanOrEqual(rect.x + rect.width, frame.maxX + 1, "rect right of the view", file: file, line: line)
            XCTAssertGreaterThanOrEqual(rect.y, frame.minY - 1, "rect above the view", file: file, line: line)
            XCTAssertLessThanOrEqual(rect.y + rect.height, frame.maxY + 1, "rect below the view", file: file, line: line)
            XCTAssertGreaterThan(rect.width, 0, file: file, line: line)
            XCTAssertGreaterThan(rect.height, 0, file: file, line: line)
        }
    }

    // MARK: - Channel 1: real link runs

    func testARealLinkRunBecomesASpanRegionCarryingItsUrl() throws {
        let text = NSMutableAttributedString(string: "I agree to the Terms and the Privacy Policy")
        text.addAttribute(.font, value: UIFont.systemFont(ofSize: 16), range: NSRange(location: 0, length: text.length))
        text.addAttribute(.link, value: URL(string: "https://example.com/terms")!, range: (text.string as NSString).range(of: "Terms"))
        let view = label { $0.attributedText = text }

        let regions = RegionProbe.probe(view, isSwiftUIHost: false).regions
        let span = try XCTUnwrap(regions.first { $0.source == .span })
        XCTAssertEqual(span.label, "Terms")
        XCTAssertEqual(span.target, "https://example.com/terms")
        XCTAssertEqual(span.charStart, (text.string as NSString).range(of: "Terms").location)
        assertInside(span.rects, view)
    }

    func testTwoLinksInOneRowResolveToTwoDistinctRects() throws {
        // The agreement row: one node, two targets. Collapsing them to one rect
        // is the failure this channel exists to prevent — a tap would open the
        // wrong document while looking like it worked.
        let text = NSMutableAttributedString(string: "Read the Terms and the Privacy Policy")
        text.addAttribute(.font, value: UIFont.systemFont(ofSize: 16), range: NSRange(location: 0, length: text.length))
        let ns = text.string as NSString
        text.addAttribute(.link, value: URL(string: "https://e/t")!, range: ns.range(of: "Terms"))
        text.addAttribute(.link, value: URL(string: "https://e/p")!, range: ns.range(of: "Privacy Policy"))
        let view = label { $0.attributedText = text }

        let spans = RegionProbe.probe(view, isSwiftUIHost: false).regions.filter { $0.source == .span }
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(Set(spans.compactMap { $0.label }), ["Terms", "Privacy Policy"])
        XCTAssertEqual(Set(spans.compactMap { $0.target }), ["https://e/t", "https://e/p"])
        let points = spans.compactMap { $0.tapPoint() }
        XCTAssertEqual(points.count, 2)
        XCTAssertNotEqual(points[0].x, points[1].x, "two links resolved to the same tap point")
    }

    func testALinkWrappedAcrossLinesYieldsOneRectPerLine() throws {
        // A wrapped phrase is not one block. Returning a single union rect would
        // put the tap point in the gutter between the two lines.
        let long = "Please read and accept our extremely long and verbose Terms of Service Agreement Document"
        let text = NSMutableAttributedString(string: long)
        text.addAttribute(.font, value: UIFont.systemFont(ofSize: 16), range: NSRange(location: 0, length: text.length))
        text.addAttribute(.link, value: "terms", range: (long as NSString).range(of: "extremely long and verbose Terms of Service Agreement Document"))
        let view = label {
            $0.frame = CGRect(x: 20, y: 100, width: 200, height: 200)
            $0.attributedText = text
        }

        let span = try XCTUnwrap(RegionProbe.probe(view, isSwiftUIHost: false).regions.first { $0.source == .span })
        XCTAssertGreaterThan(span.rects.count, 1, "a wrapped link should report one rect per line")
        assertInside(span.rects, view)
    }

    // MARK: - Channel 3b: re-colored runs

    func testAMinorityColoredRunIsSurfacedAsAColorSpanCandidate() throws {
        // The "colour the phrase, hit-test it in one gesture recognizer" pattern:
        // no link attribute exists, so colour is the only signal there is.
        let text = NSMutableAttributedString(string: "By continuing you accept the Privacy Policy")
        let ns = text.string as NSString
        text.addAttribute(.font, value: UIFont.systemFont(ofSize: 16), range: NSRange(location: 0, length: text.length))
        text.addAttribute(.foregroundColor, value: UIColor.black, range: NSRange(location: 0, length: text.length))
        text.addAttribute(.foregroundColor, value: UIColor.blue, range: ns.range(of: "Privacy Policy"))
        let view = label { $0.attributedText = text }

        let colored = try XCTUnwrap(RegionProbe.probe(view, isSwiftUIHost: false).regions.first { $0.source == .colorSpan })
        XCTAssertEqual(colored.label, "Privacy Policy")
        XCTAssertEqual(colored.color, "#FF0000FF")
        assertInside(colored.rects, view)
    }

    func testUniformlyColoredTextProducesNoColorCandidate() {
        // Every attributed string with any colour set carries a run for the whole
        // string; treating that as a highlight would mark all text tappable.
        let text = NSMutableAttributedString(string: "Just a sentence")
        text.addAttribute(.font, value: UIFont.systemFont(ofSize: 16), range: NSRange(location: 0, length: text.length))
        text.addAttribute(.foregroundColor, value: UIColor.black, range: NSRange(location: 0, length: text.length))
        let view = label { $0.attributedText = text }

        XCTAssertTrue(RegionProbe.probe(view, isSwiftUIHost: false).regions.filter { $0.source == .colorSpan }.isEmpty)
    }

    // MARK: - Channel 4: structural markers (fallback)

    func testBracketedPhrasesInASelfDrawnRowAreMarkedSuspectedAndMapped() throws {
        let view = label {
            $0.isUserInteractionEnabled = true
            $0.text = "我已阅读并同意《服务协议》和《隐私政策》"
        }
        let result = RegionProbe.probe(view, isSwiftUIHost: false)
        XCTAssertTrue(result.suspectedMultiRegion, "a bracketed row with no spans should be flagged, not silently plain")
        let markers = result.regions.filter { $0.source == .textMarker }
        XCTAssertEqual(markers.map { $0.label }, ["《服务协议》", "《隐私政策》"])
        assertInside(markers.flatMap { $0.rects }, view)
    }

    func testMarkdownLinksCarryTheirTarget() throws {
        let view = label {
            $0.isUserInteractionEnabled = true
            $0.text = "Read [Terms](https://e/t) and [Privacy](https://e/p)"
        }
        let markers = RegionProbe.probe(view, isSwiftUIHost: false).regions.filter { $0.source == .textMarker }
        XCTAssertEqual(markers.compactMap { $0.label }, ["Terms", "Privacy"])
        XCTAssertEqual(markers.compactMap { $0.target }, ["https://e/t", "https://e/p"])
    }

    func testPlainProseIsNeverGuessedToBeMultiRegion() {
        // Detection is structural, never lexical: keying on words like "agree"
        // would make the probe locale-specific and mark ordinary sentences.
        let view = label {
            $0.isUserInteractionEnabled = true
            $0.text = "By signing in you accept the User Agreement and Privacy Policy"
        }
        let result = RegionProbe.probe(view, isSwiftUIHost: false)
        XCTAssertFalse(result.suspectedMultiRegion)
        XCTAssertTrue(result.regions.isEmpty)
        // …but the grid still makes the phrase targetable by substring.
        XCTAssertNotNil(result.charGrid)
    }

    func testAnUnmarkedRowThatIsNotInteractiveIsNotFlaggedEither() {
        let view = label { $0.text = "I agree to the 《Terms》" } // no user interaction
        XCTAssertFalse(RegionProbe.probe(view, isSwiftUIHost: false).suspectedMultiRegion)
    }

    // MARK: - Channel 2: accessibility sub-elements

    func testChildAccessibilityElementsBecomeVirtualRegions() throws {
        let container = UIView(frame: CGRect(x: 0, y: 200, width: 390, height: 120))
        window.addSubview(container)
        let seat = UIAccessibilityElement(accessibilityContainer: container)
        seat.accessibilityLabel = "Seat 12A"
        seat.accessibilityFrame = CGRect(x: 40, y: 220, width: 44, height: 44)
        container.accessibilityElements = [seat]
        window.layoutIfNeeded()

        let region = try XCTUnwrap(RegionProbe.probe(container, isSwiftUIHost: false).regions.first { $0.source == .a11yVirtual })
        XCTAssertEqual(region.label, "Seat 12A")
        XCTAssertEqual(region.rects.first?.width, 44)
    }

    func testAnElementCoveringTheWholeViewIsTheViewsOwnProxyAndIsDropped() {
        let container = UIView(frame: CGRect(x: 0, y: 200, width: 390, height: 120))
        window.addSubview(container)
        let proxy = UIAccessibilityElement(accessibilityContainer: container)
        proxy.accessibilityLabel = "the whole row"
        proxy.accessibilityFrame = container.accessibilityFrame
        container.accessibilityElements = [proxy]
        window.layoutIfNeeded()

        XCTAssertTrue(
            RegionProbe.probe(container, isSwiftUIHost: false).regions.isEmpty,
            "a full-size element is the row itself; reporting it as a sub-region invents a target"
        )
    }

    func testTheVirtualChannelIsSuppressedForSwiftUIHosts() {
        // SwiftUI's elements are already captured as axElement NODES; emitting
        // them as regions too would present one target twice.
        let container = UIView(frame: CGRect(x: 0, y: 200, width: 390, height: 120))
        window.addSubview(container)
        let element = UIAccessibilityElement(accessibilityContainer: container)
        element.accessibilityLabel = "Sign in"
        element.accessibilityFrame = CGRect(x: 40, y: 220, width: 60, height: 30)
        container.accessibilityElements = [element]
        window.layoutIfNeeded()

        XCTAssertTrue(RegionProbe.probe(container, isSwiftUIHost: true).regions.isEmpty)
    }

    // MARK: - Non-text views

    func testAPlainViewProducesNothingRatherThanAnEmptyGrid() {
        let plain = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        window.addSubview(plain)
        let result = RegionProbe.probe(plain, isSwiftUIHost: false)
        XCTAssertTrue(result.regions.isEmpty)
        XCTAssertNil(result.charGrid)
        XCTAssertFalse(result.suspectedMultiRegion)
    }
}
