import SwiftUI
import UIKit
import ReticleKit

/// The keyboard trap, reproduced deliberately — the iOS port of the Android
/// sample's `LoginScenarioActivity`: a code field at the top and the submit
/// button pinned to the bottom of the screen, with no keyboard-avoidance
/// wiring, so typing leaves the system keyboard sitting on top of the button.
/// E2E asserts that the snapshot reports the keyboard, marks the button
/// `occluded-by:keyboard`, and that `act hide-keyboard` clears the way to a
/// successful submit.
final class LoginViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let status = UILabel()
        status.text = "Enter the code"
        status.font = .systemFont(ofSize: 20)
        status.accessibilityIdentifier = "login.status"

        let codeField = UITextField()
        codeField.placeholder = "SMS code"
        codeField.borderStyle = .roundedRect
        codeField.keyboardType = .numberPad
        codeField.accessibilityIdentifier = "login.codeField"

        let submit = UIButton(type: .system)
        submit.setTitle("Log in", for: .normal)
        submit.titleLabel?.font = .systemFont(ofSize: 18)
        submit.accessibilityIdentifier = "login.submitButton"
        submit.addAction(UIAction { _ in
            status.text = "Logged in: \(codeField.text ?? "")"
            Reticle.log("login_submitted", metadata: ["chars": .integer(Int64(codeField.text?.count ?? 0))])
        }, for: .touchUpInside)

        let top = UIStackView(arrangedSubviews: [status, codeField])
        top.axis = .vertical
        top.spacing = 24
        top.translatesAutoresizingMaskIntoConstraints = false
        submit.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(top)
        view.addSubview(submit)
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            top.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            top.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            // Pinned to the screen bottom — exactly where the keyboard lands.
            submit.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            submit.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            submit.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])

        Reticle.log("login_visible")
    }
}
