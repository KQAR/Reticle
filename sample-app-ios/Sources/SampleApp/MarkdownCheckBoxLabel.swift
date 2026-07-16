import UIKit

/// A self-drawn checkbox+agreement control modeled on a real login-screen
/// pattern — a single row carrying MULTIPLE bracketed links. The iOS analogue of
/// the Android sample's `MarkdownCheckBox`.
///
/// It IS a UILabel whose text is a plain string — no `.link` attribute, no child
/// view, no accessibility elements. It splits N+1 regions — toggle + one per
/// bracketed link — entirely inside its own touch handling, by resolving the
/// touch to a character index through a private TextKit stack. The links
/// deliberately mix bracket scripts — European «…» and CJK 《…》 on one row —
/// to exercise script-agnostic marker detection.
final class MarkdownCheckBoxLabel: UILabel {

    var onToggle: ((Bool) -> Void)?
    /// Invoked with the tapped link's text, e.g. "«Terms»".
    var onLink: ((String) -> Void)?

    private var checked = false
    private let body = "I have read and agree to «Terms» «Privacy» 《Data》"

    /// Open/close bracket pairs whose runs are tappable links, any script.
    private let brackets: [(String, String)] = [("«", "»"), ("《", "》")]

    init() {
        super.init(frame: .zero)
        numberOfLines = 0
        isUserInteractionEnabled = true
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func render() {
        let full = (checked ? "☑ " : "☐ ") + body
        attributedText = NSAttributedString(string: full, attributes: [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: UIColor.label,
        ])
    }

    /// UTF-16 ranges of each bracketed link in the current text.
    private func linkRanges(in full: NSString) -> [(String, NSRange)] {
        var out: [(String, NSRange)] = []
        for (open, close) in brackets {
            var search = NSRange(location: 0, length: full.length)
            while true {
                let o = full.range(of: open, options: [], range: search)
                if o.location == NSNotFound { break }
                let tail = NSRange(location: o.location + o.length, length: full.length - o.location - o.length)
                let c = full.range(of: close, options: [], range: tail)
                if c.location == NSNotFound { break }
                let run = NSRange(location: o.location, length: c.location + c.length - o.location)
                out.append((full.substring(with: run), run))
                search = NSRange(location: c.location + c.length, length: full.length - c.location - c.length)
            }
        }
        return out
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self) else { return }
        let full = (attributedText?.string ?? "") as NSString
        if let index = LabelHitTester.characterIndex(in: self, at: point),
           let hit = linkRanges(in: full).first(where: { NSLocationInRange(index, $0.1) }) {
            onLink?(hit.0)
        } else {
            checked.toggle()
            render()
            onToggle?(checked)
        }
    }
}
