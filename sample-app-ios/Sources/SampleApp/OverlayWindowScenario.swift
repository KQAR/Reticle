import SwiftUI
import UIKit
import ReticleKit

/// A REAL second `UIWindow` raised over the app — the iOS shape that Android's
/// `AlertDialog` has, and the one the window-occlusion path exists for.
///
/// The distinction matters and is why this scenario exists separately from the
/// system-dialog one: a `UIAlertController` is presented INSIDE the presenting
/// window, so there is no second window to occlude anything. An overlay window (a
/// blocking loader, an in-app banner, a debug HUD — all common) is a genuine
/// second window at a higher `windowLevel`, and a tap aimed at the screen beneath
/// it lands on the overlay instead. That is exactly what `occluded-by` must say.
final class OverlayWindowViewController: UIViewController {

    private let status = UILabel()
    private var overlayWindow: UIWindow?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        status.text = "No overlay"
        status.font = .systemFont(ofSize: 20)
        status.accessibilityIdentifier = "overlay.status"

        let trigger = UIButton(type: .system)
        trigger.setTitle("Show blocking overlay", for: .normal)
        trigger.accessibilityIdentifier = "overlay.trigger"
        trigger.addAction(UIAction { [weak self] _ in self?.showOverlay() }, for: .touchUpInside)

        // The control the overlay will cover: a tap aimed here after the overlay is
        // up must be reported as landing on the overlay, not on this button.
        let covered = UIButton(type: .system)
        covered.setTitle("Underneath", for: .normal)
        covered.accessibilityIdentifier = "overlay.covered"
        covered.addAction(UIAction { [weak self] _ in
            self?.status.text = "Underneath tapped"
            Reticle.log("overlay_underneath_tapped", metadata: [:])
        }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [status, trigger, covered])
        stack.axis = .vertical
        stack.spacing = 24
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])

        Reticle.log("overlay_visible", metadata: ["screen": .text("overlayWindow")])
    }

    private func showOverlay() {
        guard let scene = view.window?.windowScene else { return }
        let window = UIWindow(windowScene: scene)
        // Above the normal level: this is what makes it an occluder rather than
        // another sibling view.
        window.windowLevel = .alert
        window.backgroundColor = UIColor.black.withAlphaComponent(0.6)

        let host = UIViewController()
        host.view.backgroundColor = .clear
        let label = UILabel()
        label.text = "Blocking overlay"
        label.textColor = .white
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.accessibilityIdentifier = "overlay.label"
        label.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(label)

        let dismiss = UIButton(type: .system)
        dismiss.setTitle("Dismiss overlay", for: .normal)
        dismiss.accessibilityIdentifier = "overlay.dismiss"
        dismiss.addAction(UIAction { [weak self] _ in
            self?.overlayWindow?.isHidden = true
            self?.overlayWindow = nil
            self?.status.text = "Overlay dismissed"
            Reticle.log("overlay_dismissed", metadata: [:])
        }, for: .touchUpInside)
        dismiss.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(dismiss)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.view.centerYAnchor),
            dismiss.centerXAnchor.constraint(equalTo: host.view.centerXAnchor),
            dismiss.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 24),
        ])

        window.rootViewController = host
        window.isHidden = false
        overlayWindow = window
        status.text = "Overlay shown"
        Reticle.log("overlay_shown", metadata: ["windowLevel": .text("alert")])
    }
}
