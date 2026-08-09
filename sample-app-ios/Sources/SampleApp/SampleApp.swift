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
            // E2E hook: when a scenario is requested, route to it *directly* as
            // the root rather than pushing onto the home List. A selection-driven
            // push depends on the row's NavigationLink being instantiated, but
            // `List` renders lazily, so a row below the fold never activates. The
            // direct route sidesteps that entirely and is stable no matter how
            // long the scenario list grows.
            if let tag = initialScenario() {
                NavigationView {
                    scenarioDestination(tag)
                        .onAppear {
                            Reticle.log("scenario_opened", metadata: ["scenario": .text("scenario.\(tag)")])
                        }
                }
                .navigationViewStyle(.stack)
            } else {
                HomeView()
            }
        }
    }
}

/// E2E hook: `RETICLE_SAMPLE_SCENARIO=checkout|agreements|wheelPicker|list|canvasControl|webview|swiftui|tabbar|login|permission|overlayWindow|dialog|lottieDialog|webLottieDialog|webDomBlocked|webComponentDialog|lottieOnlyDialog|webFrames`
/// (via `SIMCTL_CHILD_…`) opens that scenario directly, so scripted runs don't
/// depend on synthesizing a navigation tap first.
private func initialScenario() -> String? {
    ProcessInfo.processInfo.environment["RETICLE_SAMPLE_SCENARIO"]
}

/// One row of the sample home list — the single source of truth shared by the
/// home list and the direct e2e route.
private struct ScenarioEntry: Identifiable {
    let tag: String
    let title: String
    let subtitle: String
    var testId: String { "scenario.\(tag)" }
    var id: String { tag }
}

private let scenarioEntries: [ScenarioEntry] = [
    ScenarioEntry(tag: "checkout", title: "Checkout controls",
                  subtitle: "Button tap, status mutation, text input, and app logs"),
    ScenarioEntry(tag: "agreements", title: "Agreement regions",
                  subtitle: "Link attribute, text markers, char grid, and color runs"),
    ScenarioEntry(tag: "wheelPicker", title: "Wheel picker",
                  subtitle: "A two-component UIPickerView exposed through accessibility"),
    ScenarioEntry(tag: "list", title: "Long list",
                  subtitle: "60 lazy rows; far-down rows are absent until scrolled"),
    ScenarioEntry(tag: "canvasControl", title: "Canvas control regions",
                  subtitle: "Self-drawn segments exposed as accessibility sub-elements"),
    ScenarioEntry(tag: "webview", title: "WebView DOM",
                  subtitle: "Native title bar with a full-screen WKWebView underneath"),
    ScenarioEntry(tag: "swiftui", title: "SwiftUI boundary",
                  subtitle: "Addressable vs unaddressable elements and markdown links"),
    ScenarioEntry(tag: "tabbar", title: "Tab bar",
                  subtitle: "Four-item TabView with per-tab pages"),
    ScenarioEntry(tag: "login", title: "Login keyboard trap",
                  subtitle: "Bottom submit button that the keyboard covers"),
    ScenarioEntry(tag: "permission", title: "System permission prompt",
                  subtitle: "Another process's alert: invisible to the tree, visible as lost focus"),
    ScenarioEntry(tag: "overlayWindow", title: "Overlay window",
                  subtitle: "A real second UIWindow that occludes the screen beneath it"),
    ScenarioEntry(tag: "dialog", title: "System dialog",
                  subtitle: "UIAlertController raised over the scenario"),
    ScenarioEntry(tag: "lottieDialog", title: "Lottie dialog",
                  subtitle: "Native dialog with a real Lottie animation view"),
    ScenarioEntry(tag: "webLottieDialog", title: "Web Lottie dialog",
                  subtitle: "lottie-web modal rendered inside a WKWebView"),
    ScenarioEntry(tag: "webDomBlocked", title: "Web DOM blocked",
                  subtitle: "An unreadable DOM degrades to one opaque node: dom:unavailable"),
    ScenarioEntry(tag: "webComponentDialog", title: "Web component dialog",
                  subtitle: "Custom-element modal with open shadow-root content"),
    ScenarioEntry(tag: "webFrames", title: "Frame walls",
                  subtitle: "Sandboxed / cross-origin / scaled / scrolling iframes"),
    ScenarioEntry(tag: "lottieOnlyDialog", title: "Lottie-only dialog",
                  subtitle: "Whole dialog (text + buttons) baked into one Lottie"),
    ScenarioEntry(tag: "touchRouting", title: "Touch routing layers",
                  subtitle: "Claiming overlay / delaying scroll view: which one eats a tap"),
]

/// The destination view for a scenario tag — shared by the home list rows and
/// the direct e2e route so the two never drift.
@MainActor @ViewBuilder
private func scenarioDestination(_ tag: String) -> some View {
    switch tag {
    case "checkout":
        ScenarioScreen { CheckoutViewController() }.navigationTitle("Checkout")
    case "agreements":
        ScenarioScreen { AgreementViewController() }.navigationTitle("Agreements")
    case "wheelPicker":
        ScenarioScreen { WheelPickerViewController() }.navigationTitle("Wheel picker")
    case "list":
        ListScenarioView().navigationTitle("Long list")
    case "canvasControl":
        ScenarioScreen { CanvasControlViewController() }.navigationTitle("Canvas control")
    case "touchRouting":
        ScenarioScreen { TouchRoutingViewController() }.navigationTitle("Touch routing")
    case "webview":
        ScenarioScreen { WebViewScenarioViewController() }.navigationTitle("WebView DOM")
    case "swiftui":
        SwiftUIBoundaryView().navigationTitle("SwiftUI")
    case "tabbar":
        TabBarScenarioView().navigationTitle("Tab bar")
    case "login":
        ScenarioScreen { LoginViewController() }
            .navigationTitle("Login")
            // Defeat SwiftUI's automatic keyboard avoidance: the trap only
            // reproduces when the button stays put and the keyboard covers it.
            .ignoresSafeArea(.keyboard)
    case "permission":
        ScenarioScreen { PermissionViewController() }.navigationTitle("Permission prompt")
    case "overlayWindow":
        ScenarioScreen { OverlayWindowViewController() }.navigationTitle("Overlay window")
    case "dialog":
        ScenarioScreen { SystemDialogViewController() }.navigationTitle("System dialog")
    case "lottieDialog":
        ScenarioScreen { LottieDialogViewController() }.navigationTitle("Lottie dialog")
    case "webLottieDialog":
        ScenarioScreen { WebLottieDialogViewController() }.navigationTitle("Web Lottie dialog")
    case "webDomBlocked":
        ScenarioScreen { WebDomBlockedViewController() }.navigationTitle("Web DOM blocked")
    case "webComponentDialog":
        ScenarioScreen { WebComponentDialogViewController() }.navigationTitle("Web component dialog")
    case "webFrames":
        ScenarioScreen { WebFramesScenarioViewController() }.navigationTitle("Frame walls")
    case "lottieOnlyDialog":
        ScenarioScreen { LottieOnlyDialogViewController() }.navigationTitle("Lottie-only dialog")
    default:
        EmptyView()
    }
}

struct HomeView: View {
    @State private var pushed: String?

    var body: some View {
        NavigationView {
            List(scenarioEntries) { entry in
                NavigationLink(
                    destination: scenarioDestination(entry.tag),
                    tag: entry.tag,
                    selection: Binding(
                        get: { pushed },
                        set: { newValue in
                            pushed = newValue
                            if newValue == entry.tag {
                                Reticle.log("scenario_opened", metadata: ["scenario": .text(entry.testId)])
                            }
                        }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).font(.headline)
                        Text(entry.subtitle).font(.subheadline).foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                .accessibilityIdentifier(entry.testId)
            }
            .navigationTitle("Reticle Sample")
            .onAppear {
                Reticle.log("home_visible", metadata: ["scenarioCount": .integer(Int64(scenarioEntries.count))])
            }
        }
        .navigationViewStyle(.stack)
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
