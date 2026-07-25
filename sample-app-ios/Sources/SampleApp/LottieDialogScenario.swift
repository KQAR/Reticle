import UIKit
import Lottie
import ReticleKit

/// A native dialog whose content includes a *real* Lottie animation view — the
/// iOS port of the Android sample's `LottieDialogScenarioActivity`. From
/// Reticle's side the `LottieAnimationView` is an opaque animated surface, so
/// this scenario probes whether the recognizable elements around it (title,
/// message, button) are still captured with the right content and frames.
final class LottieDialogViewController: UIViewController {

    private let status = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        status.text = "Idle"
        status.font = .systemFont(ofSize: 20)
        status.accessibilityIdentifier = "lottieDialog.status"

        let trigger = UIButton(type: .system)
        trigger.setTitle("Show status dialog", for: .normal)
        trigger.titleLabel?.font = .systemFont(ofSize: 18)
        trigger.accessibilityIdentifier = "lottieDialog.trigger"
        trigger.addAction(UIAction { [weak self] _ in
            Reticle.log("lottie_dialog_opened", metadata: ["kind": .text("native")])
            self?.showLottieDialog()
        }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [status, trigger])
        stack.axis = .vertical
        stack.spacing = 24
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])

        Reticle.log("lottie_dialog_visible", metadata: ["screen": .text("lottieDialog")])
    }

    private func showLottieDialog() {
        let alert = LottieAlertViewController { [weak self] in
            self?.status.text = "Done"
            Reticle.log("lottie_dialog_confirmed", metadata: ["choice": .text("done")])
        }
        alert.modalPresentationStyle = .overFullScreen
        alert.modalTransitionStyle = .crossDissolve
        present(alert, animated: true)
    }
}

/// A dimmed-background card presented over the scenario — a custom modal (rather
/// than `UIAlertController`, which cannot host an arbitrary Lottie subview).
private final class LottieAlertViewController: UIViewController {

    private let onDone: () -> Void

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.45)

        let card = UIView()
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 16
        card.translatesAutoresizingMaskIntoConstraints = false

        let animation = LottieAnimationView(name: "lottie_anim", bundle: .module)
        animation.accessibilityIdentifier = "lottieDialog.animation"
        animation.isAccessibilityElement = true
        animation.loopMode = .loop
        animation.contentMode = .scaleAspectFit
        animation.play()
        animation.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            animation.widthAnchor.constraint(equalToConstant: 96),
            animation.heightAnchor.constraint(equalToConstant: 96),
        ])

        let title = UILabel()
        title.text = "Please wait"
        title.font = .boldSystemFont(ofSize: 18)
        title.accessibilityIdentifier = "lottieDialog.title"

        let message = UILabel()
        message.text = "Processing your request..."
        message.font = .systemFont(ofSize: 15)
        message.textColor = .secondaryLabel
        message.numberOfLines = 0
        message.textAlignment = .center
        message.accessibilityIdentifier = "lottieDialog.message"

        let done = UIButton(type: .system)
        done.setTitle("Done", for: .normal)
        done.titleLabel?.font = .systemFont(ofSize: 16)
        done.accessibilityIdentifier = "lottieDialog.done"
        done.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: true) { self?.onDone() }
        }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [animation, title, message, done])
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        view.addSubview(card)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 280),
        ])
    }
}
