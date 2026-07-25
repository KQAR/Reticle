import UIKit
import ReticleKit

/// The iOS analogue of the Android sample's canvas-control scenario: a view that
/// draws its segments itself, so the view tree sees ONE node and the segment
/// labels/rects are only recoverable through the accessibility container it
/// exposes.
///
/// iOS has two legal ways to be a container, and an app picks either:
///
///  - set the `accessibilityElements` array (the modern shorthand);
///  - implement the `UIAccessibilityContainer` METHODS
///    (`accessibilityElementCount()` / `accessibilityElement(at:)` /
///    `index(ofAccessibilityElement:)`) and build elements on demand — the
///    original documented approach, still what a large dynamic control uses.
///
/// The scenario ships one control of each so the harness can't pass by covering
/// only the shorthand. There is deliberately no touch-delegate analogue: UIKit
/// expands a hit area by overriding `point(inside:with:)`, which is app code with
/// no introspectable rect — a structural boundary, not a missing channel.
final class CanvasControlViewController: UIViewController {

    private let status = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        status.text = "Idle"
        status.font = .systemFont(ofSize: 20)
        status.accessibilityIdentifier = "canvas.status"

        let segments = CanvasSegmentedControl(labels: ["Daily", "Weekly", "Monthly"], style: .elementsArray)
        segments.accessibilityIdentifier = "canvas.segments"
        segments.onSegment = { [weak self] label in
            self?.status.text = "Segment: \(label)"
            Reticle.log("canvas_segment_picked", metadata: ["label": .text(label), "container": .text("elements")])
        }

        let seats = CanvasSegmentedControl(labels: ["A1", "A2", "A3"], style: .containerMethods)
        seats.accessibilityIdentifier = "canvas.seats"
        seats.onSegment = { [weak self] label in
            self?.status.text = "Seat: \(label)"
            Reticle.log("canvas_seat_picked", metadata: ["label": .text(label), "container": .text("methods")])
        }

        let stack = UIStackView(arrangedSubviews: [status, segments, seats])
        stack.axis = .vertical
        stack.spacing = 24
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            segments.heightAnchor.constraint(equalToConstant: 56),
            seats.heightAnchor.constraint(equalToConstant: 56),
        ])

        Reticle.log("canvas_control_visible", metadata: ["channels": .text("a11yVirtual")])
    }
}

/// A self-drawn segmented control: N boxes with their titles painted into the
/// view's own `draw(_:)`, no subviews, tap hit-tested privately.
final class CanvasSegmentedControl: UIView {

    /// Which of the two container conventions this instance exposes.
    enum ContainerStyle {
        case elementsArray
        case containerMethods
    }

    var onSegment: ((String) -> Void)?

    private let labels: [String]
    private let style: ContainerStyle
    private var selected = 0

    init(labels: [String], style: ContainerStyle) {
        self.labels = labels
        self.style = style
        super.init(frame: .zero)
        backgroundColor = .clear
        isAccessibilityElement = false
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap(_:))))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: UIColor.white,
        ]
        for (index, label) in labels.enumerated() {
            let box = boundsOf(index)
            ctx.setFillColor((index == selected ? UIColor.systemBlue : UIColor.systemGray).cgColor)
            ctx.fill(box)
            let size = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(
                at: CGPoint(x: box.midX - size.width / 2, y: box.midY - size.height / 2),
                withAttributes: attrs
            )
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let x = recognizer.location(in: self).x
        let index = Int(x / segmentWidth())
        guard labels.indices.contains(index) else { return }
        select(index)
    }

    private func select(_ index: Int) {
        selected = index
        setNeedsDisplay()
        onSegment?(labels[index])
    }

    private func segmentWidth() -> CGFloat {
        bounds.width > 0 ? bounds.width / CGFloat(labels.count) : 1
    }

    private func boundsOf(_ index: Int) -> CGRect {
        CGRect(
            x: CGFloat(index) * segmentWidth() + 2,
            y: 2,
            width: segmentWidth() - 4,
            height: bounds.height - 4
        ).integral
    }

    // MARK: - Accessibility container

    private func makeElement(_ index: Int) -> UIAccessibilityElement {
        let element = UIAccessibilityElement(accessibilityContainer: self)
        element.accessibilityLabel = labels[index]
        element.accessibilityTraits = .button
        element.accessibilityFrameInContainerSpace = boundsOf(index)
        return element
    }

    /// Style 1: the shorthand array, rebuilt on layout so the frames stay right.
    private var cachedElements: [UIAccessibilityElement]?

    override func layoutSubviews() {
        super.layoutSubviews()
        cachedElements = nil
        if style == .elementsArray {
            accessibilityElements = labels.indices.map(makeElement)
        }
    }

    /// Style 2: the container METHODS, with elements built on demand and no
    /// `accessibilityElements` array ever set.
    override func accessibilityElementCount() -> Int {
        guard style == .containerMethods else { return super.accessibilityElementCount() }
        return labels.count
    }

    override func accessibilityElement(at index: Int) -> Any? {
        guard style == .containerMethods else { return super.accessibilityElement(at: index) }
        guard labels.indices.contains(index) else { return nil }
        if cachedElements == nil { cachedElements = labels.indices.map(makeElement) }
        return cachedElements?[index]
    }

    override func index(ofAccessibilityElement element: Any) -> Int {
        guard style == .containerMethods else { return super.index(ofAccessibilityElement: element) }
        if cachedElements == nil { cachedElements = labels.indices.map(makeElement) }
        guard let element = element as? UIAccessibilityElement,
              let index = cachedElements?.firstIndex(of: element) else { return NSNotFound }
        return index
    }
}
