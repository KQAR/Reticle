import SwiftUI
import UIKit
import ReticleKit

/// Multi-region text cases that collapse into one view but still need precise
/// phrase-level targeting — the iOS port of the Android sample's
/// `AgreementScenarioActivity`, using the idioms real iOS apps actually ship:
/// a UITextView `.link` run, a self-drawn bracketed-links label, a self-drawn
/// plain-phrase label, and a re-colored (highlight-means-link) label.
final class AgreementViewController: UIViewController, UITextViewDelegate {

    private let status: UILabel = {
        let label = UILabel()
        label.text = "Agreement scenarios"
        label.font = .systemFont(ofSize: 20)
        label.numberOfLines = 0
        label.accessibilityIdentifier = "agreement.status"
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let stack = UIStackView(arrangedSubviews: [
            status,
            linkAttributeRow(),
            markdownRow(),
            plainPhraseRow(),
            colorRow(),
        ])
        stack.axis = .vertical
        stack.spacing = 24
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
        ])

        Reticle.log("agreements_visible", metadata: ["cases": .integer(4)])
    }

    /// NSAttributedString `.link` inside a non-editable UITextView — the iOS
    /// analogue of Android's ClickableSpan row. The link range is structural
    /// (an attribute run), but the view still reports as ONE node.
    private func linkAttributeRow() -> UITextView {
        let text = "I have read and agree to the Terms"
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: UIColor.label,
        ])
        attributed.addAttribute(
            .link,
            value: URL(string: "reticle-sample://terms")!,
            range: (text as NSString).range(of: "Terms")
        )
        let textView = UITextView()
        textView.attributedText = attributed
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = self
        textView.accessibilityIdentifier = "agreement.span"
        return textView
    }

    func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
        status.text = "opened agreement (link attribute)"
        Reticle.log("agreement_link_clicked", metadata: ["via": .text("NSAttributedString.link")])
        return false
    }

    private func markdownRow() -> MarkdownCheckBoxLabel {
        let row = MarkdownCheckBoxLabel()
        row.accessibilityIdentifier = "agreement.markdown"
        row.onToggle = { [weak self] checked in
            self?.status.text = checked ? "agreed (markdown toggle)" : "unchecked"
            Reticle.log("markdown_toggled", metadata: ["checked": .bool(checked)])
        }
        row.onLink = { [weak self] linkText in
            self?.status.text = "opened \(linkText) (markdown link)"
            Reticle.log("markdown_link_clicked", metadata: ["via": .text("touchesEnded"), "link": .text(linkText)])
        }
        return row
    }

    private func plainPhraseRow() -> PlainPhraseLabel {
        let row = PlainPhraseLabel()
        row.accessibilityIdentifier = "agreement.plain"
        row.onPhrase = { [weak self] phrase in
            self?.status.text = "opened \(phrase) (plain phrase)"
            Reticle.log("plain_phrase_clicked", metadata: ["phrase": .text(phrase)])
        }
        row.onPlain = { [weak self] in
            self?.status.text = "tapped agreement text (no phrase)"
            Reticle.log("plain_text_clicked")
        }
        return row
    }

    /// The "highlight = link" pattern: a ForegroundColor run over "Terms of
    /// Service" with a whole-row tap handler — no `.link` attribute at all.
    private func colorRow() -> UILabel {
        let text = "Continue means you accept the Terms of Service"
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: UIColor.label,
        ])
        attributed.addAttribute(
            .foregroundColor,
            value: UIColor(red: 0x1A / 255.0, green: 0x73 / 255.0, blue: 0xE8 / 255.0, alpha: 1),
            range: (text as NSString).range(of: "Terms of Service")
        )
        let label = UILabel()
        label.attributedText = attributed
        label.numberOfLines = 0
        label.isUserInteractionEnabled = true
        label.accessibilityIdentifier = "agreement.color"
        label.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(colorRowTapped)))
        return label
    }

    @objc private func colorRowTapped() {
        status.text = "tapped color row (manual hit-test)"
        Reticle.log("color_row_clicked", metadata: ["highlight": .text("Terms of Service")])
    }
}
