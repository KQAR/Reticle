import UIKit

/// The hardest real case, ported from the Android sample's `PlainPhraseAgreement`:
/// a self-drawn clickable text with MULTIPLE tappable phrases that carry NO
/// bracket / markdown / link-attribute markers at all. Only "User Agreement" and
/// "Privacy Policy" are meant to be tappable; the phrase boundaries live purely
/// in this control's private touch handling.
///
/// Nothing structural marks the phrases, so an observer cannot DISCOVER them as
/// regions — but because the rendered text is visible, a char grid with exact
/// per-character X positions still lets an agent target a phrase by substring.
final class PlainPhraseLabel: UILabel {

    var onPhrase: ((String) -> Void)?
    var onPlain: (() -> Void)?

    private let body = "By signing in you accept the User Agreement and Privacy Policy"
    private let phrases = ["User Agreement", "Privacy Policy"]

    init() {
        super.init(frame: .zero)
        numberOfLines = 0
        isUserInteractionEnabled = true
        // Non-default metrics on purpose: char-grid extraction must resolve a
        // phrase precisely even with larger text + kerning + line spacing, so
        // keeping them here doubles as a standing regression (mirrors the
        // Android sample's letterSpacing/lineSpacing choices).
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 8
        paragraph.lineHeightMultiple = 1.3
        attributedText = NSAttributedString(string: body, attributes: [
            .font: UIFont.systemFont(ofSize: 18),
            .foregroundColor: UIColor.label,
            .kern: 1.8,
            .paragraphStyle: paragraph,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func ranges(in full: NSString) -> [(String, NSRange)] {
        phrases.compactMap { phrase in
            let r = full.range(of: phrase)
            return r.location == NSNotFound ? nil : (phrase, r)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        let full = (attributedText?.string ?? "") as NSString
        if let index = LabelHitTester.characterIndex(in: self, at: point),
           let hit = ranges(in: full).first(where: { NSLocationInRange(index, $0.1) }) {
            onPhrase?(hit.0)
        } else {
            onPlain?()
        }
    }
}
