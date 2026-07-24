import SwiftUI
import UIKit
import ReticleKit

/// A native alert raised over the scenario — the iOS port of the Android
/// sample's `SystemDialogScenarioActivity`. `UIAlertController` presents its own
/// view hierarchy over the presenting screen, so this is the scenario that
/// proves Reticle surfaces a modal alert's own content (title / message /
/// buttons) rather than only the screen behind it.
///
/// A true system-owned prompt (a permission sheet) lives in another process and
/// is out of reach for an in-process agent — this is the app-owned alert, which
/// is exactly what Reticle can and should recognize.
final class SystemDialogViewController: UIViewController {

    private let status = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        status.text = "No choice yet"
        status.font = .systemFont(ofSize: 20)
        status.accessibilityIdentifier = "dialog.status"

        let trigger = UIButton(type: .system)
        trigger.setTitle("Delete account", for: .normal)
        trigger.titleLabel?.font = .systemFont(ofSize: 18)
        trigger.accessibilityIdentifier = "dialog.trigger"
        trigger.addAction(UIAction { [weak self] _ in
            Reticle.log("dialog_opened", metadata: ["kind": .text("alert")])
            self?.showConfirmDialog()
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

        Reticle.log("dialog_visible", metadata: ["screen": .text("systemDialog")])
    }

    private func showConfirmDialog() {
        let alert = UIAlertController(
            title: "Delete account?",
            message: "This action cannot be undone.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            self?.status.text = "Deleted"
            Reticle.log("dialog_confirmed", metadata: ["choice": .text("delete")])
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.status.text = "Cancelled"
            Reticle.log("dialog_dismissed", metadata: ["choice": .text("cancel")])
        })
        present(alert, animated: true)
    }
}
