import UIKit
import UserNotifications
import ReticleKit

/// A real system permission alert: the one on-screen thing an in-process agent
/// structurally CANNOT see.
///
/// The alert belongs to another process, so it appears in no window of this app and
/// in no node of the tree — a capture taken while it is up looks like an ordinary
/// screen with every control still "tappable", yet input goes to the alert. Reticle
/// cannot show it, but it can report that this app is no longer the active
/// recipient of input (`screen.windowFocused == false`), which is a fact and enough
/// for an agent to stop and look. The Android twin is
/// `PermissionScenarioActivity`.
final class PermissionViewController: UIViewController {

    private let status = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        status.text = "No prompt yet"
        status.font = .systemFont(ofSize: 20)
        status.accessibilityIdentifier = "permission.status"

        let trigger = UIButton(type: .system)
        trigger.setTitle("Request notifications", for: .normal)
        trigger.accessibilityIdentifier = "permission.trigger"
        trigger.addAction(UIAction { [weak self] _ in self?.requestNotifications() }, for: .touchUpInside)

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
        Reticle.log("permission_visible", metadata: ["screen": .text("permission")])
    }

    private func requestNotifications() {
        Reticle.log("permission_requested", metadata: ["permission": .text("notifications")])
        status.text = "Prompt requested"
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.status.text = granted ? "Prompt granted" : "Prompt dismissed"
                Reticle.log("permission_result", metadata: ["granted": .text(granted ? "yes" : "no")])
            }
        }
    }
}
