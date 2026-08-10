import UIKit
import ReticleKit

/// Why a dispatched touch can change nothing — isolated one layer at a time.
///
/// Measured on a real device against a KMP / Compose Multiplatform app: every
/// `act tap` on the home screen reported `dispatched=true` and produced zero
/// changes, while the same app's other screens drove fine. The two facts the
/// agent could see were that the hit view was always the toolkit's full-screen
/// input layer (`androidx.compose.ui.window.OverlayInputView`), and that its
/// recognizer chain contained `UIScrollViewDelayedTouchesBeganGestureRecognizer`
/// — i.e. a canvas that claims every hit, inside a scroll view that delays the
/// touches it forwards.
///
/// Neither fact alone explains a dead tap, so this scenario ships the
/// combinations rather than one guess: a self-drawn target, wrapped in a
/// `hitTest`-claiming overlay, a `delaysContentTouches` scroll view, both, and
/// again for a target whose behaviour lives in a `UITapGestureRecognizer`
/// instead of its own `touchesEnded`. Each row has a status label a working tap
/// flips from `idle` to `hit`.
///
/// **Measured on an iPhone 13 Pro Max / iOS 26 with `act tap`:** every row lands
/// except the four involving a recognizer and a claiming overlay together —
/// whether the recognizer sits UNDER the overlay (`recognizerOverlay`,
/// `recognizerBoth`) or ON it (`overlayRecognizer`, `overlayRecognizerScroll`),
/// which is where a toolkit actually puts it, the overlay being its input layer.
/// So neither the overlay nor the scroll view eats a synthesized touch on its
/// own, and the delayed-touches recognizer — the thing that looked guilty from
/// the outside — is irrelevant.
///
/// **And it is not a synthesis gap.** The same rows run on a SIMULATOR, where
/// Reticle drives real HID through UIKit's full event pipeline — what a finger
/// uses — fail identically. UIKit gathers recognizers from the views it
/// TRAVERSES while hit-testing; an overlay that returns `self` without
/// descending is never traversed past. Recorded in `docs/boundaries.md`; keep
/// this scenario as the guard that the other rows stay drivable.
///
/// No row uses a `UIControl`: that would answer `act activate` and hide the very
/// failure under test.
final class TouchRoutingViewController: UIViewController {

    private enum Variant: String, CaseIterable {
        case plain
        case overlay
        case scroll
        case both
        case recognizer
        case recognizerOverlay
        case recognizerScroll
        case recognizerBoth
        case overlayRecognizer
        case overlayRecognizerScroll

        var title: String {
            switch self {
            case .plain: return "Plain canvas"
            case .overlay: return "Under claiming overlay"
            case .scroll: return "In delaying scroll view"
            case .both: return "Overlay in scroll view"
            case .recognizer: return "Recognizer only"
            case .recognizerOverlay: return "Recognizer under overlay"
            case .recognizerScroll: return "Recognizer in scroll view"
            case .recognizerBoth: return "Recognizer in overlay+scroll"
            case .overlayRecognizer: return "Recognizer ON the overlay"
            case .overlayRecognizerScroll: return "Recognizer ON overlay, in scroll"
            }
        }

        /// Whether the target fires from a `UITapGestureRecognizer` instead of
        /// its own `touchesEnded`. A synthesized `UITouch` carries no recognizer
        /// list — UIKit fills that in while hit-testing a REAL event — so a
        /// control whose behaviour lives in a recognizer is the one shape that
        /// can be reached, dispatched to, and still do nothing.
        var usesRecognizer: Bool {
            self == .recognizer || self == .recognizerOverlay
                || self == .recognizerScroll || self == .recognizerBoth
        }

        var wrapsInOverlay: Bool {
            self == .overlay || self == .both || self == .recognizerOverlay || self == .recognizerBoth
                || self == .overlayRecognizer || self == .overlayRecognizerScroll
        }

        /// The recognizer sits on the CLAIMING OVERLAY itself rather than on a
        /// view beneath it — which is where a cross-platform toolkit actually
        /// puts it, since the overlay IS its input layer.
        var recognizerOnOverlay: Bool {
            self == .overlayRecognizer || self == .overlayRecognizerScroll
        }
        var wrapsInScrollView: Bool {
            self == .scroll || self == .both || self == .recognizerScroll || self == .recognizerBoth
                || self == .overlayRecognizerScroll
        }
    }

    private var statuses: [Variant: UILabel] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let rows = Variant.allCases.map { row(for: $0) }
        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])

        Reticle.log("touch_routing_visible", metadata: [
            "variants": .text(Variant.allCases.map(\.rawValue).joined(separator: ",")),
        ])
    }

    /// One row: a status label plus the button wrapped in whatever layers this
    /// variant is testing. The button's rect stays the same in all four, so the
    /// same tap geometry exercises every combination.
    private func row(for variant: Variant) -> UIView {
        let status = UILabel()
        status.text = "idle"
        status.font = .systemFont(ofSize: 15)
        status.accessibilityIdentifier = "touchRouting.\(variant.rawValue).status"
        statuses[variant] = status

        let button = CanvasTapTarget(
            title: variant.title,
            handlesTouches: !variant.usesRecognizer && !variant.recognizerOnOverlay)
        button.accessibilityIdentifier = "touchRouting.\(variant.rawValue).button"
        button.onTap = { [weak self] in
            self?.statuses[variant]?.text = "hit"
            Reticle.log("touch_routing_hit", metadata: ["variant": .text(variant.rawValue)])
        }
        if variant.usesRecognizer {
            button.addGestureRecognizer(UITapGestureRecognizer(target: button, action: #selector(CanvasTapTarget.recognized)))
        }

        var host: UIView = button
        if variant.wrapsInOverlay {
            let overlay = ClaimingOverlayHost(content: host)
            if variant.recognizerOnOverlay {
                overlay.addGestureRecognizer(
                    UITapGestureRecognizer(target: button, action: #selector(CanvasTapTarget.recognized)))
            }
            host = overlay
        }
        if variant.wrapsInScrollView {
            host = DelayingScrollHost(content: host)
        }
        host.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let stack = UIStackView(arrangedSubviews: [status, host])
        stack.axis = .vertical
        stack.spacing = 6
        return stack
    }
}

/// A self-drawn button: no `UIControl`, no recognizer, so the ONLY way it fires
/// is a `touchesEnded` that actually arrived.
final class CanvasTapTarget: UIView {

    var onTap: (() -> Void)?

    private let title: String
    /// False for the recognizer variants: the target must NOT also fire from
    /// `touchesEnded`, or a recognizer failure would be masked by the fallback.
    private let handlesTouches: Bool

    init(title: String, handlesTouches: Bool = true) {
        self.title = title
        self.handlesTouches = handlesTouches
        super.init(frame: .zero)
        backgroundColor = .secondarySystemFill
        layer.cornerRadius = 10
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: UIColor.label,
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(
            at: CGPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2),
            withAttributes: attributes)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard handlesTouches else { return }
        guard let point = touches.first?.location(in: self), bounds.contains(point) else { return }
        onTap?()
    }

    @objc func recognized() { onTap?() }
}

/// The `hitTest`-claiming canvas: it answers EVERY hit inside itself, then routes
/// the touch to the content by hand — the shape a cross-platform toolkit uses to
/// own input for a whole scene.
final class ClaimingOverlayHost: UIView {

    private let content: UIView

    init(content: UIView) {
        self.content = content
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        bounds.contains(point) ? self : nil
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        // Forward by geometry, since hit-testing was taken over above.
        let local = touch.location(in: content)
        if content.bounds.contains(local) {
            content.touchesEnded(touches, with: event)
        }
    }
}

/// A scroll view with `delaysContentTouches` left ON (the UIKit default), which
/// is what puts `UIScrollViewDelayedTouchesBeganGestureRecognizer` in the chain:
/// a press shorter than the delay can be cancelled before the content ever sees
/// `touchesBegan`.
final class DelayingScrollHost: UIScrollView {

    init(content: UIView) {
        super.init(frame: .zero)
        delaysContentTouches = true
        canCancelContentTouches = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor),
            content.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
