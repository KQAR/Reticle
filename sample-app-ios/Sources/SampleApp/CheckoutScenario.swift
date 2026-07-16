import SwiftUI
import UIKit
import ReticleKit

/// Basic native controls used to prove selector actions and runtime mutation —
/// the iOS port of the Android sample's `CheckoutScenarioActivity`.
final class CheckoutViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let status = UILabel()
        status.text = "Cart: 3 items"
        status.font = .systemFont(ofSize: 20)
        status.accessibilityIdentifier = "checkout.status"

        let payButton = UIButton(type: .system)
        payButton.setTitle("Pay now", for: .normal)
        payButton.titleLabel?.font = .systemFont(ofSize: 18)
        payButton.accessibilityIdentifier = "checkout.payButton"
        payButton.addAction(UIAction { _ in
            status.text = "Paid!"
            Reticle.log("checkout_paid", metadata: ["itemCount": .integer(3), "method": .text("card")])
        }, for: .touchUpInside)

        // Exercises both ASCII input and (once wired) the non-ASCII path.
        let nameField = UITextField()
        nameField.placeholder = "Name on card"
        nameField.borderStyle = .roundedRect
        nameField.accessibilityIdentifier = "checkout.nameField"

        let stack = UIStackView(arrangedSubviews: [status, payButton, nameField])
        stack.axis = .vertical
        stack.spacing = 24
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])

        Reticle.attachMetadata(testId: "checkout.payButton", ["screen": .text("checkout"), "variant": .text("primary")])
        Reticle.log("checkout_visible", metadata: ["cartId": .text("cart-123"), "itemCount": .integer(3)])
    }
}
