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

    init?(view: UIView) {
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
            guard drawn.width > 0 else { return nil }
            let textStorage = NSTextStorage(attributedString: attributed)
            let layoutManager = NSLayoutManager()
            let textContainer = NSTextContainer(size: CGSize(width: drawn.width, height: .greatestFiniteMagnitude))
            textContainer.lineFragmentPadding = 0
            textContainer.maximumNumberOfLines = label.numberOfLines
            textContainer.lineBreakMode = label.lineBreakMode
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
    func screenRects(for range: NSRange, in view: UIView) -> [Rect] {
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
    func charLines(in view: UIView) -> ([CharLine], Bool) {
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

    private func screenRect(containerRect: CGRect, in view: UIView) -> Rect {
        let topLeft = screenPoint(containerPoint: containerRect.origin, in: view)
        return Rect(x: topLeft.x, y: topLeft.y, width: Double(containerRect.width), height: Double(containerRect.height))
    }

    /// Container coords -> view coords -> window coords -> screen coords,
    /// mirroring SnapshotCapture's frame math.
    private func screenPoint(containerPoint: CGPoint, in view: UIView) -> (x: Double, y: Double) {
        let inView = CGPoint(x: containerPoint.x + originInView.x, y: containerPoint.y + originInView.y)
        guard let window = view.window else {
            return (Double(inView.x), Double(inView.y))
        }
        let inWindow = view.convert(inView, to: nil)
        return (Double(inWindow.x + window.frame.origin.x), Double(inWindow.y + window.frame.origin.y))
    }
}
#endif
