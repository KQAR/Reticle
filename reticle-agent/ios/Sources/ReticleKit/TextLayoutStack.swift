import Foundation
import ReticleProtocol
#if canImport(UIKit)
import UIKit

/// Text geometry for the region probe: character-range rects and per-character
/// boundary X positions, in SCREEN coordinates.
///
/// - `UITextView` lends its own TextKit stack, so geometry is exact. (Reading
///   `layoutManager` on iOS 16+ drops the view into TextKit-1 compatibility
///   mode; that is the standard, supported fallback and keeps geometry public.)
/// - `UILabel` exposes no layout API, so an equivalent TextKit stack is rebuilt
///   from its attributed text and drawn rect (`textRect(forBounds:…)`). This is
///   the same reconstruction self-drawn rows use for their own hit-testing.
@MainActor
struct TextLayoutStack {
    let attributed: NSAttributedString
    private let manager: NSLayoutManager
    private let container: NSTextContainer
    /// Keeps a rebuilt UILabel stack alive (a borrowed UITextView stack is nil).
    private let storage: NSTextStorage?
    /// Origin of the text container in the view's own coordinate space.
    private let originInView: CGPoint
    /// Set when there is no backing view to convert through: an accessibility
    /// element's frame is already in screen coordinates, so the container origin IS
    /// the screen origin.
    private let screenOrigin: CGPoint?

    init?(view: UIView) {
        screenOrigin = nil
        switch view {
        case let textView as UITextView:
            guard let attributed = textView.attributedText, attributed.length > 0 else { return nil }
            self.attributed = attributed
            manager = textView.layoutManager
            container = textView.textContainer
            storage = nil
            originInView = CGPoint(
                x: textView.textContainerInset.left - textView.contentOffset.x,
                y: textView.textContainerInset.top - textView.contentOffset.y
            )
        case let label as UILabel:
            guard let attributed = TextLayoutStack.effectiveAttributedText(of: label) else { return nil }
            self.attributed = attributed
            let drawn = label.textRect(forBounds: label.bounds, limitedToNumberOfLines: label.numberOfLines)
            // Clamp to the label's own width: `textRect` answers with the width the
            // text WANTS under the label's break mode, which for the default
            // `.byTruncatingTail` is the whole string on one line — wider than the
            // label. Laying out in that width produces one long line whose rects run
            // off the right edge of a label that visibly wraps.
            let layoutWidth = label.numberOfLines == 1 ? drawn.width : min(drawn.width, label.bounds.width)
            guard layoutWidth > 0 else { return nil }
            let textStorage = NSTextStorage(attributedString: TextLayoutStack.wrapped(attributed, for: label))
            let layoutManager = NSLayoutManager()
            let textContainer = NSTextContainer(size: CGSize(width: layoutWidth, height: .greatestFiniteMagnitude))
            textContainer.lineFragmentPadding = 0
            textContainer.maximumNumberOfLines = label.numberOfLines
            textContainer.lineBreakMode = TextLayoutStack.wrappingMode(for: label)
            layoutManager.addTextContainer(textContainer)
            textStorage.addLayoutManager(layoutManager)
            manager = layoutManager
            container = textContainer
            storage = textStorage
            originInView = drawn.origin
        default:
            return nil
        }
    }

    /// A stack for text that has NO backing view to borrow geometry from: a SwiftUI
    /// accessibility element, whose attributed label and screen frame are all that
    /// exist. Same reconstruction as the `UILabel` case, anchored to the screen rect
    /// instead of a view.
    init?(attributed: NSAttributedString, screenFrame: Rect) {
        guard attributed.length > 0, screenFrame.width > 0 else { return nil }
        self.attributed = attributed
        let textStorage = NSTextStorage(attributedString: attributed)
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(size: CGSize(width: screenFrame.width, height: .greatestFiniteMagnitude))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        manager = layoutManager
        container = textContainer
        storage = textStorage
        originInView = .zero
        screenOrigin = CGPoint(x: screenFrame.x, y: screenFrame.y)
    }

    /// The line-break mode the rebuilt container must use to lay out like the
    /// label does.
    ///
    /// Not simply `label.lineBreakMode`: UILabel defaults to `.byTruncatingTail`,
    /// and on a MULTI-line label UIKit wraps every line and truncates only the
    /// last — while an `NSTextContainer` set to `.byTruncatingTail` produces
    /// exactly one line. Copying the mode verbatim therefore collapsed every
    /// ordinary wrapped label (`numberOfLines = 0`, default break mode — an
    /// agreement row, in other words) into a single line fragment, so its char
    /// grid claimed one line running off the right edge and a link on the second
    /// line resolved to a rect outside the label. Measured by
    /// `TextLayoutStackTests`; the Android side never had this because it reads
    /// the real `Layout` rather than rebuilding one.
    /// The same correction applied to the string's own paragraph styles.
    ///
    /// This is the half that actually bites: `UILabel.attributedText` carries an
    /// `NSParagraphStyle` whose `lineBreakMode` is the label's, and a paragraph
    /// style OVERRIDES the container — so fixing only `NSTextContainer` left every
    /// default-configured multi-line label laying out as one endless line.
    private static func wrapped(_ attributed: NSAttributedString, for label: UILabel) -> NSAttributedString {
        guard label.numberOfLines != 1 else { return attributed }
        let mode = wrappingMode(for: label)
        let out = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: out.length)
        out.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            guard let style = value as? NSParagraphStyle, style.lineBreakMode != mode else { return }
            guard let mutable = style.mutableCopy() as? NSMutableParagraphStyle else { return }
            mutable.lineBreakMode = mode
            out.addAttribute(.paragraphStyle, value: mutable, range: range)
        }
        return out
    }

    private static func wrappingMode(for label: UILabel) -> NSLineBreakMode {
        guard label.numberOfLines != 1 else { return label.lineBreakMode }
        switch label.lineBreakMode {
        case .byTruncatingHead, .byTruncatingMiddle, .byTruncatingTail, .byClipping:
            return .byWordWrapping
        default:
            return label.lineBreakMode
        }
    }

    /// A label set via plain `text` still needs font/color attributes for the
    /// rebuilt stack to measure like the real one.
    private static func effectiveAttributedText(of label: UILabel) -> NSAttributedString? {
        if let attributed = label.attributedText, attributed.length > 0 { return attributed }
        guard let text = label.text, !text.isEmpty else { return nil }
        return NSAttributedString(string: text, attributes: [
            .font: label.font ?? UIFont.systemFont(ofSize: UIFont.labelFontSize),
            .foregroundColor: label.textColor ?? UIColor.label,
        ])
    }

    // MARK: - Range rects

    /// Per-line screen rects for a character range. A range wrapping across
    /// lines yields one rect per line — never collapsed to a single block.
    func screenRects(for range: NSRange, in view: UIView?) -> [Rect] {
        guard range.length > 0, range.location + range.length <= attributed.length else { return [] }
        let glyphRange = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rects: [CGRect] = []
        manager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
            in: container
        ) { rect, _ in
            if rect.width > 0, rect.height > 0 { rects.append(rect) }
        }
        return rects.map { screenRect(containerRect: $0, in: view) }
    }

    // MARK: - Char grid lines

    /// Per-line-fragment character boundary X positions (glyph-exact, straight
    /// from the layout manager — robust across fonts, kerning, and spacing).
    /// `approximate` flags mixed-direction text, where a logical range can map
    /// to a non-contiguous visual span.
    func charLines(in view: UIView?) -> ([CharLine], Bool) {
        let fullGlyphs = manager.glyphRange(for: container)
        guard fullGlyphs.length > 0 else { return ([], false) }
        let text = attributed.string as NSString

        var lines: [CharLine] = []
        var lineIndex = 0
        manager.enumerateLineFragments(forGlyphRange: fullGlyphs) { _, usedRect, _, glyphRange, _ in
            let charRange = self.manager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let start = charRange.location
            let end = charRange.location + charRange.length
            var xs: [Double] = []
            xs.reserveCapacity(charRange.length + 1)
            for offset in start...end {
                let x: CGFloat
                if offset >= end || offset >= text.length {
                    // The trailing boundary of the fragment: the used width, so
                    // a soft wrap never jumps to the next line's left edge.
                    x = usedRect.maxX
                } else {
                    let glyph = self.manager.glyphIndexForCharacter(at: offset)
                    if glyph < glyphRange.location || glyph >= glyphRange.location + glyphRange.length {
                        x = usedRect.maxX
                    } else {
                        // location(forGlyphAt:) is relative to the fragment origin.
                        x = usedRect.origin.x + self.manager.location(forGlyphAt: glyph).x
                    }
                }
                xs.append(Double(x))
            }
            let topLeft = self.screenPoint(containerPoint: CGPoint(x: 0, y: usedRect.minY), in: view)
            let bottomLeft = self.screenPoint(containerPoint: CGPoint(x: 0, y: usedRect.maxY), in: view)
            let originX = self.screenPoint(containerPoint: .zero, in: view).x
            lines.append(CharLine(
                line: lineIndex,
                start: start,
                end: end,
                top: topLeft.y,
                bottom: bottomLeft.y,
                xOffsets: xs.map { $0 + originX }
            ))
            lineIndex += 1
        }

        // BiDi honesty: per-offset X stays correct, but a logical [start, end)
        // range on a mixed-direction line is not one visual run.
        let approximate = containsRightToLeftText(attributed.string)
        return (lines, approximate)
    }

    private func containsRightToLeftText(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            (0x0590...0x08FF).contains(scalar.value) || (0xFB1D...0xFDFF).contains(scalar.value)
                || (0xFE70...0xFEFF).contains(scalar.value)
        }
    }

    // MARK: - Coordinate conversion

    private func screenRect(containerRect: CGRect, in view: UIView?) -> Rect {
        let topLeft = screenPoint(containerPoint: containerRect.origin, in: view)
        return Rect(x: topLeft.x, y: topLeft.y, width: Double(containerRect.width), height: Double(containerRect.height))
    }

    /// Container coords -> view coords -> window coords -> screen coords,
    /// mirroring SnapshotCapture's frame math.
    private func screenPoint(containerPoint: CGPoint, in view: UIView?) -> (x: Double, y: Double) {
        // No view: the container was anchored to a screen rect to begin with.
        if let screenOrigin {
            return (Double(containerPoint.x + screenOrigin.x), Double(containerPoint.y + screenOrigin.y))
        }
        let inView = CGPoint(x: containerPoint.x + originInView.x, y: containerPoint.y + originInView.y)
        guard let view, let window = view.window else {
            return (Double(inView.x), Double(inView.y))
        }
        let inWindow = view.convert(inView, to: nil)
        return (Double(inWindow.x + window.frame.origin.x), Double(inWindow.y + window.frame.origin.y))
    }
}
#endif
