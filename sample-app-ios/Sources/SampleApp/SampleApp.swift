import SwiftUI
import UIKit
import ReticleKit

// The linked demo, structured like the Android sample: a home list where each
// row opens one focused Reticle scenario, so a report stays readable instead of
// mixing every probe target on one screen. It starts the agent explicitly at
// launch (the linked path).
@main
struct SampleApp: App {
    init() {
        Reticle.start()
        Reticle.log("SampleApp launched")
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}

/// E2E hook: `RETICLE_SAMPLE_SCENARIO=checkout|agreements|webview|swiftui|tabbar`
/// (via `SIMCTL_CHILD_…`) opens that scenario directly, so scripted runs don't
/// depend on synthesizing a navigation tap first.
private func initialScenario() -> String? {
    ProcessInfo.processInfo.environment["RETICLE_SAMPLE_SCENARIO"]
}

struct HomeView: View {
    @State private var pushed = initialScenario()

    var body: some View {
        NavigationView {
            List {
                scenarioRow(
                    title: "Checkout controls",
                    subtitle: "Button tap, status mutation, text input, and app logs",
                    testId: "scenario.checkout",
                    tag: "checkout"
                ) {
                    ScenarioScreen { CheckoutViewController() }
                        .navigationTitle("Checkout")
                }
                scenarioRow(
                    title: "Agreement regions",
                    subtitle: "Link attribute, text markers, char grid, and color runs",
                    testId: "scenario.agreements",
                    tag: "agreements"
                ) {
                    ScenarioScreen { AgreementViewController() }
                        .navigationTitle("Agreements")
                }
                scenarioRow(
                    title: "WebView DOM",
                    subtitle: "Native title bar with a full-screen WKWebView underneath",
                    testId: "scenario.webview",
                    tag: "webview"
                ) {
                    ScenarioScreen { WebViewScenarioViewController() }
                        .navigationTitle("WebView DOM")
                }
                scenarioRow(
                    title: "SwiftUI boundary",
                    subtitle: "Addressable vs unaddressable elements and markdown links",
                    testId: "scenario.swiftui",
                    tag: "swiftui"
                ) {
                    SwiftUIBoundaryView()
                        .navigationTitle("SwiftUI")
                }
                scenarioRow(
                    title: "Tab bar",
                    subtitle: "Four-item TabView with per-tab pages",
                    testId: "scenario.tabbar",
                    tag: "tabbar"
                ) {
                    TabBarScenarioView()
                        .navigationTitle("Tab bar")
                }
            }
            .navigationTitle("Reticle Sample")
            .onAppear {
                Reticle.log("home_visible", metadata: ["scenarioCount": .integer(5)])
            }
        }
        .navigationViewStyle(.stack)
    }

    /// A visible scenario row that is also programmatically pushable via the
    /// e2e scenario hook (selection-driven NavigationLink).
    private func scenarioRow<Destination: View>(
        title: String,
        subtitle: String,
        testId: String,
        tag: String,
        @ViewBuilder destination: () -> Destination
    ) -> some View {
        NavigationLink(
            destination: destination(),
            tag: tag,
            selection: Binding(
                get: { pushed },
                set: { newValue in
                    pushed = newValue
                    if newValue == tag {
                        Reticle.log("scenario_opened", metadata: ["scenario": .text(testId)])
                    }
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
        }
        .accessibilityIdentifier(testId)
    }
}

/// Hosts a UIKit scenario view controller inside the SwiftUI navigation shell —
/// the scenarios themselves are deliberately UIKit, matching how the real apps
/// that motivated them are built.
struct ScenarioScreen<VC: UIViewController>: UIViewControllerRepresentable {
    let make: () -> VC

    func makeUIViewController(context: Context) -> VC { make() }
    func updateUIViewController(_ uiViewController: VC, context: Context) {}
}
