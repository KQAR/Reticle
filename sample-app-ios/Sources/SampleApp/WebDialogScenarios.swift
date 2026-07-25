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
