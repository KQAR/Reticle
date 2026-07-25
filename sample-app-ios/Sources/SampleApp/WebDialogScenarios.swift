import UIKit
import WebKit
import ReticleKit

/// A modal rendered inside a WKWebView by `lottie-web` (a real Lottie animation)
/// plus DOM title / message / button — the iOS port of the Android sample's
/// `WebLottieDialogScenarioActivity`.
final class WebLottieDialogViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let webView = SampleWebFixtures.makeLottieDialogWebView()
        webView.accessibilityIdentifier = "webLottie.webView"
        pin(webView)
        Reticle.log("web_lottie_visible", metadata: ["fixture": .text("webLottie")])
    }

    private func pin(_ webView: WKWebView) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

/// A modal rendered inside a WKWebView as a Web Component — a custom
/// `<confirm-dialog>` element whose content lives in an open shadow root — the
/// iOS port of the Android sample's `WebComponentDialogScenarioActivity`.
final class WebComponentDialogViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let webView = SampleWebFixtures.makeWebComponentDialogWebView()
        webView.accessibilityIdentifier = "webComponent.webView"
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        Reticle.log("web_component_visible", metadata: ["fixture": .text("webComponent")])
    }
}


/// A web view whose DOM becomes unreadable on demand, so the bridge's honest L0
/// degrade is observable: the view stays one opaque node AND says why, via
/// `dom:unavailable`.
///
/// Why not the Android twin (a page calling `alert()`)? Measured on iOS 26.3: a
/// page's `alert()` never reaches the app's `WKUIDelegate` in this configuration —
/// the controller is alive, `uiDelegate` is set (no `deinit` fires), and the
/// statement after `alert()` runs immediately, so WebKit simply skips the panel.
/// The page therefore blocks its own JS thread with a bounded busy loop instead:
/// the same condition an `alert()` creates (`evaluateJavaScript` cannot call back),
/// deterministic, and self-clearing so recovery is observable too. When a JS modal
/// DOES appear on iOS it is an app-presented `UIAlertController`, which the
/// system-dialog scenario already covers.
final class WebDomBlockedViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // A native label on the same screen: the degrade must be scoped to the web
        // view, not a blackout of the whole capture.
        let status = UILabel()
        status.text = "Native content still captured"
        status.font = .systemFont(ofSize: 16)
        status.accessibilityIdentifier = "domBlocked.status"
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)

        let webView = SampleWebFixtures.makeDomBlockedWebView()
        webView.accessibilityIdentifier = "domBlocked.webView"
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            status.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        Reticle.log("web_dom_blocked_visible", metadata: ["fixture": .text("domBlocked")])
    }
}
