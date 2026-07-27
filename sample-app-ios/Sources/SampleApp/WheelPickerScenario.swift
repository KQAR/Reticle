import UIKit
import ReticleKit

/// The iOS wheel picker — the twin of the Android sample's
/// `WheelPickerScenarioActivity`, and the one place the two platforms are
/// genuinely *not* symmetric.
///
/// Android draws a `NumberPicker`'s neighbouring values onto the wheel canvas, so
/// nothing but the selection exists as a view. `UIPickerView` instead builds a
/// real subview per visible row and exposes the whole wheel through
/// accessibility, one element per component, carrying the selection as
/// `accessibilityValue` with the `.adjustable` trait. So the same on-screen
/// control yields a different amount of readable evidence per platform, and the
/// scenario exists to measure exactly that — not to make one side match the
/// other.
///
/// One picker with two components, deliberately: unlike Android (two sibling
/// widgets, distinguished by testId) a `UIPickerView` is ONE view with ONE
/// identifier, so its two wheels can only be told apart by their sub-elements —
/// the ambiguity lives inside the node instead of between nodes.
final class WheelPickerViewController: UIViewController {

    private let status = UILabel()
    private let picker = UIPickerView()

    private let hours = (0..<24).map { String(format: "%02d", $0) }
    private let minutes = ["00", "15", "30", "45"]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        status.text = "Idle"
        status.font = .systemFont(ofSize: 20)
        status.accessibilityIdentifier = "wheel.status"

        picker.dataSource = self
        picker.delegate = self
        picker.accessibilityIdentifier = "wheel.picker"
        picker.selectRow(hours.firstIndex(of: "09") ?? 0, inComponent: 0, animated: false)
        picker.selectRow(0, inComponent: 1, animated: false)

        let confirm = UIButton(type: .system)
        confirm.setTitle("Confirm time", for: .normal)
        confirm.titleLabel?.font = .systemFont(ofSize: 18)
        confirm.accessibilityIdentifier = "wheel.confirm"
        confirm.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.status.text = "Time: \(self.pickedTime)"
            Reticle.log("wheel_confirmed", metadata: ["time": .text(self.pickedTime)])
        }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [status, picker, confirm])
        stack.axis = .vertical
        stack.spacing = 24
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            picker.heightAnchor.constraint(equalToConstant: 200),
        ])

        Reticle.log("wheel_visible", metadata: [
            "hour": .text(hours[picker.selectedRow(inComponent: 0)]),
            "minute": .text(minutes[picker.selectedRow(inComponent: 1)]),
        ])
    }

    private var pickedTime: String {
        "\(hours[picker.selectedRow(inComponent: 0)]):\(minutes[picker.selectedRow(inComponent: 1)])"
    }

    private func values(for component: Int) -> [String] {
        component == 0 ? hours : minutes
    }
}

extension WheelPickerViewController: UIPickerViewDataSource, UIPickerViewDelegate {
    func numberOfComponents(in pickerView: UIPickerView) -> Int { 2 }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        values(for: component).count
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        values(for: component)[row]
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        let event = component == 0 ? "wheel_hour_changed" : "wheel_minute_changed"
        Reticle.log(event, metadata: ["value": .text(values(for: component)[row])])
    }

    // Names the two wheels for accessibility — without this both components read
    // as an unlabelled adjustable value, and "which wheel is 09 on" is guesswork.
    func pickerView(_ pickerView: UIPickerView, accessibilityLabelForComponent component: Int) -> String? {
        component == 0 ? "Hour" : "Minute"
    }
}
