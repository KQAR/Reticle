import SwiftUI
import UIKit
import WebKit
import ReticleKit

/// Full-screen embedded WKWebView below the navigation bar — the iOS port of
/// the Android sample's `WebViewScenarioActivity`, backing Reticle's read-only
/// DOM bridge with the same complex fixture (forms, disabled/ARIA states,
/// scaled/fixed layout, images, shadow DOM, iframe).
final class WebViewScenarioViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let webView = SampleWebFixtures.makeComplexWebView()
        webView.accessibilityIdentifier = "checkout.webView"
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        Reticle.log("webview_visible", metadata: ["fixture": .text("complex")])
    }
}
