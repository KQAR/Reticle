import UIKit

/// Maps a touch point inside a UILabel to a character index by rebuilding the
/// label's layout with TextKit. UILabel exposes no layout API (unlike Android's
/// `TextView.getLayout()`), so real-world multi-target rows on iOS each carry a
/// private stack like this (YYText, TTTAttributedLabel, hand-rolled login rows)
/// — which is exactly why nothing structural marks the tap targets for an
/// outside observer.
enum LabelHitTester {
    /// Character index (UTF-16, NSRange-compatible) under `point`, or nil when
    /// the point is not on any glyph.
    static func characterIndex(in label: UILabel, at point: CGPoint) -> Int? {
        guard let attributed = label.attributedText, attributed.length > 0 else { return nil }
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = label.numberOfLines
        container.lineBreakMode = label.lineBreakMode
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)

        let glyph = manager.glyphIndex(for: point, in: container)
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        return manager.characterIndexForGlyph(at: glyph)
    }
}
