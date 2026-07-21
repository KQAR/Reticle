import SwiftUI
import ReticleKit

/// A four-item TabView probe: SwiftUI's TabView is backed by UITabBarController,
/// so the bottom bar items are real UIKit views (the view-tree walk), while each
/// page is SwiftUI reached through the accessibility bridge — both recognition
/// paths in one scenario. Switching tabs mutates `tabbar.status`, so a tap on a
/// bar item has an observable side effect instead of merely "not erroring".
struct TabBarScenarioView: View {
    @State private var selection = "home"

    var body: some View {
        TabView(selection: $selection) {
            tabPage(name: "Home", icon: "house", tag: "home")
            tabPage(name: "Orders", icon: "list.bullet", tag: "orders")
            tabPage(name: "Messages", icon: "envelope", tag: "messages")
            tabPage(name: "Profile", icon: "person", tag: "profile")
        }
        .onChange(of: selection) { newValue in
            Reticle.log("tab_selected", metadata: ["tab": .text(newValue)])
        }
    }

    private func tabPage(name: String, icon: String, tag: String) -> some View {
        VStack(spacing: 16) {
            Text("\(name) page")
                .font(.title2)
                .accessibilityIdentifier("tabbar.page.\(tag)")
            Text("Selected: \(selection)")
                .accessibilityIdentifier("tabbar.status")
        }
        .tabItem { Label(name, systemImage: icon) }
        .tag(tag)
    }
}
