import XCTest
import ReticleProtocol
@testable import ReticleKit

/// The char grid — the last-resort channel that makes a phrase targetable when a
/// control exposes no spans, no children and no accessibility sub-elements.
///
/// Its guarantee is not "roughly right": every X comes from the laid-out text,
/// so the invariants below (one entry per character boundary, monotonic within a
/// line, contiguous line ranges, screen coordinates) are what a caller relies on
/// when it maps a substring to a tap point. The Kotlin twin's `CharGridTest`
/// asserts the same shape over `android.text.Layout`.
@MainActor
final class TextLayoutStackTests: XCTestCase {

    private var window: UIWindow!

    override func setUp() {
        super.setUp()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
    }

    override func tearDown() {
        window = nil
        super.tearDown()
    }

    private func label(text: String, width: CGFloat = 320, lines: Int = 0) -> UILabel {
        let label = UILabel(frame: CGRect(x: 20, y: 100, width: width, height: 200))
        label.numberOfLines = lines
        label.font = .systemFont(ofSize: 16)
        label.text = text
        window.addSubview(label)
        window.layoutIfNeeded()
        return label
    }

    func testTheGridHasOneBoundaryPerCharacterPlusTheTrailingEdge() throws {
        let view = label(text: "Hello world")
        let stack = try XCTUnwrap(TextLayoutStack(view: view))
        let (lines, approximate) = stack.charLines(in: view)

        XCTAssertEqual(lines.count, 1)
        let line = try XCTUnwrap(lines.first)
        XCTAssertEqual(line.start, 0)
        XCTAssertEqual(line.end, 11)
        // n characters -> n+1 boundaries: the last entry is the right edge of the
        // last glyph, without which the final character has no rect.
        XCTAssertEqual(line.xOffsets.count, line.end - line.start + 1)
        XCTAssertFalse(approximate, "plain LTR text is exact, not a best effort")
    }

    func testBoundariesAdvanceLeftToRightAndStartAtTheTextOrigin() throws {
        let view = label(text: "Hello world")
        let stack = try XCTUnwrap(TextLayoutStack(view: view))
        let line = try XCTUnwrap(stack.charLines(in: view).0.first)

        for (a, b) in zip(line.xOffsets, line.xOffsets.dropFirst()) {
            XCTAssertLessThanOrEqual(a, b, "character boundaries must not go backwards")
        }
        // Screen coordinates, not view-local ones: the label sits at x=20.
        XCTAssertEqual(line.xOffsets.first ?? -1, 20, accuracy: 1)
        XCTAssertGreaterThan(line.bottom, line.top)
    }

    func testProportionalGlyphsProduceUnequalAdvancesRatherThanAnInterpolation() throws {
        // The predecessor of this code interpolated equal widths and drifted on
        // mixed text; 'i' and 'W' must not be the same width.
        let view = label(text: "iWiW")
        let stack = try XCTUnwrap(TextLayoutStack(view: view))
        let xs = try XCTUnwrap(stack.charLines(in: view).0.first).xOffsets
        let narrow = xs[1] - xs[0]
        let wide = xs[2] - xs[1]
        XCTAssertGreaterThan(wide, narrow + 1, "advances look interpolated, not laid out")
    }

    /// Also the regression test for the bug these tests found: the label here is
    /// configured the ordinary way (`numberOfLines = 0`, default break mode), and
    /// the rebuilt stack used to lay it out as ONE endless line — because
    /// `UILabel.attributedText` carries a paragraph style whose `lineBreakMode` is
    /// `.byTruncatingTail`, which overrides the text container. Every char grid and
    /// every link rect on a wrapped label was wrong, pointing off the right edge.
    func testWrappedTextYieldsContiguousLinesStackedDownTheScreen() throws {
        let view = label(text: "The quick brown fox jumps over the lazy dog near the river bank", width: 150)
        let stack = try XCTUnwrap(TextLayoutStack(view: view))
        let lines = stack.charLines(in: view).0

        XCTAssertGreaterThan(lines.count, 1)
        for (a, b) in zip(lines, lines.dropFirst()) {
            XCTAssertEqual(a.end, b.start, "line ranges must tile the text with no gap or overlap")
            XCTAssertGreaterThan(b.top, a.top, "later lines must sit lower on screen")
        }
        XCTAssertEqual(lines.map { $0.line }, Array(0..<lines.count))
    }

    func testARangeRectCoversTheSubstringAndNotTheWholeLine() throws {
        let text = "Read the Terms carefully"
        let view = label(text: text)
        let stack = try XCTUnwrap(TextLayoutStack(view: view))
        let range = (text as NSString).range(of: "Terms")
        let rect = try XCTUnwrap(stack.screenRects(for: range, in: view).first)

        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertLessThan(rect.width, view.bounds.width * 0.8, "a 5-character rect should not span the row")
        XCTAssertGreaterThan(rect.x, 20, "the rect should start after the leading text, not at the label origin")
    }

    func testTheGridAndARangeRectAgreeOnWhereASubstringIs() throws {
        // The two paths a caller can take to the same phrase must not disagree:
        // `--region "Terms"` resolves through the grid, a discovered span through
        // the rects.
        let text = "Read the Terms carefully"
        let view = label(text: text)
        let stack = try XCTUnwrap(TextLayoutStack(view: view))
        let range = (text as NSString).range(of: "Terms")

        let rect = try XCTUnwrap(stack.screenRects(for: range, in: view).first)
        let line = try XCTUnwrap(stack.charLines(in: view).0.first)
        let gridLeft = line.xOffsets[range.location]
        XCTAssertEqual(rect.x, gridLeft, accuracy: 1.5)
    }

    func testAnOutOfBoundsRangeReturnsNothingRatherThanCrashing() throws {
        let view = label(text: "short")
        let stack = try XCTUnwrap(TextLayoutStack(view: view))
        XCTAssertTrue(stack.screenRects(for: NSRange(location: 3, length: 99), in: view).isEmpty)
        XCTAssertTrue(stack.screenRects(for: NSRange(location: 0, length: 0), in: view).isEmpty)
    }

    func testRightToLeftTextIsReportedAsApproximateRatherThanConfidentlyWrong() throws {
        // A logical range over bidirectional text can map to a non-contiguous
        // visual span, so the flag is the honest answer — the row for it is in
        // docs/boundaries.md.
        let view = label(text: "Read the شروط الخدمة carefully")
        let stack = try XCTUnwrap(TextLayoutStack(view: view))
        XCTAssertTrue(stack.charLines(in: view).1, "mixed-direction text must be flagged approximate")
    }

    func testATextViewLendsItsOwnStackAndStaysWithinItsFrame() throws {
        let textView = UITextView(frame: CGRect(x: 10, y: 300, width: 300, height: 120))
        textView.font = .systemFont(ofSize: 16)
        textView.text = "Terms of service"
        window.addSubview(textView)
        window.layoutIfNeeded()

        let stack = try XCTUnwrap(TextLayoutStack(view: textView))
        let rect = try XCTUnwrap(stack.screenRects(for: NSRange(location: 0, length: 5), in: textView).first)
        XCTAssertGreaterThanOrEqual(rect.x, 10)
        XCTAssertLessThanOrEqual(rect.x + rect.width, 310)
    }

    func testAViewWithNoTextHasNoStackAtAll() {
        let plain = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        window.addSubview(plain)
        XCTAssertNil(TextLayoutStack(view: plain))
        XCTAssertNil(TextLayoutStack(view: label(text: "")))
    }

    func testAScreenAnchoredStackNeedsNoViewToPlaceItsRects() throws {
        // The SwiftUI path: there is no view to convert through, so the frame the
        // accessibility element reports IS the origin.
        let attributed = NSAttributedString(string: "Terms and Privacy", attributes: [.font: UIFont.systemFont(ofSize: 16)])
        let frame = Rect(x: 24, y: 620, width: 300, height: 40)
        let stack = try XCTUnwrap(TextLayoutStack(attributed: attributed, screenFrame: frame))

        let rect = try XCTUnwrap(stack.screenRects(for: NSRange(location: 0, length: 5), in: nil).first)
        XCTAssertEqual(rect.x, 24, accuracy: 1)
        XCTAssertEqual(rect.y, 620, accuracy: 4)
    }
}
