import UIKit
import Lottie
import ReticleKit

/// The dialog IS a Lottie: the entire card — title, message, and both buttons —
/// is drawn by one Lottie animation (text + shape layers). Nothing inside is a
/// native view. Like real apps that ship Lottie dialogs, the view hit-tests taps
/// against the known button regions (composition coords) and fires the matching
/// callback — the handler a Reticle tap must trigger.
final class LottieOnlyDialogViewController: UIViewController {

    private let status = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        status.text = "Idle"
        status.font = .systemFont(ofSize: 20)
        status.accessibilityIdentifier = "lottieOnly.status"

        let trigger = UIButton(type: .system)
        trigger.setTitle("Show Lottie dialog", for: .normal)
        trigger.titleLabel?.font = .systemFont(ofSize: 18)
        trigger.accessibilityIdentifier = "lottieOnly.trigger"
        trigger.addAction(UIAction { [weak self] _ in
            Reticle.log("lottie_only_opened", metadata: ["kind": .text("lottie-canvas")])
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

        Reticle.log("lottie_only_visible", metadata: ["screen": .text("lottieOnly")])
    }

    private func showLottieDialog() {
        let modal = LottieCanvasDialogViewController { [weak self] choice in
            self?.status.text = choice == .delete ? "Deleted" : "Cancelled"
            Reticle.log("lottie_only_choice", metadata: ["choice": .text(choice == .delete ? "delete" : "cancel")])
        }
        modal.modalPresentationStyle = .overFullScreen
        modal.modalTransitionStyle = .crossDissolve
        present(modal, animated: true)
    }
}

private final class LottieCanvasDialogViewController: UIViewController {

    enum Choice { case cancel, delete }

    // Composition-space button hit rects (see Resources/lottie_dialog.json):
    // buttons centered at (85,170) and (215,170), each 116x46, in a 300x220 comp.
    private static let compSize = CGSize(width: 300, height: 220)
    private static let cancelRect = CGRect(x: 27, y: 147, width: 116, height: 46)
    private static let deleteRect = CGRect(x: 157, y: 147, width: 116, height: 46)

    private let onChoice: (Choice) -> Void
    private let animationView = LottieAnimationView(animation: LottieAnimation.named("lottie_dialog", bundle: .module))

    init(onChoice: @escaping (Choice) -> Void) {
        self.onChoice = onChoice
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.45)

        animationView.accessibilityIdentifier = "lottieOnly.canvas"
        animationView.contentMode = .scaleAspectFit
        animationView.loopMode = .loop
        animationView.play()
        animationView.isUserInteractionEnabled = true
        animationView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(onTap(_:))))
        animationView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(animationView)
        NSLayoutConstraint.activate([
            animationView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            animationView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            animationView.widthAnchor.constraint(equalToConstant: 300),
            animationView.heightAnchor.constraint(equalToConstant: 220),
        ])
    }

    @objc private func onTap(_ gr: UITapGestureRecognizer) {
        let p = gr.location(in: animationView)
        // Map the view-space tap to composition coords (aspect-fit, centered).
        let vw = animationView.bounds.width, vh = animationView.bounds.height
        let s = min(vw / Self.compSize.width, vh / Self.compSize.height)
        let offX = (vw - Self.compSize.width * s) / 2
        let offY = (vh - Self.compSize.height * s) / 2
        let comp = CGPoint(x: (p.x - offX) / s, y: (p.y - offY) / s)
        if Self.cancelRect.contains(comp) {
            dismiss(animated: true) { self.onChoice(.cancel) }
        } else if Self.deleteRect.contains(comp) {
            dismiss(animated: true) { self.onChoice(.delete) }
        }
    }
}
