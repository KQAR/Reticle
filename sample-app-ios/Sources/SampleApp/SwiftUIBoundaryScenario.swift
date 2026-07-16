import SwiftUI
import UIKit
import ReticleKit

/// The SwiftUI addressability boundary demo (the original single-screen sample):
/// a button WITH an `.accessibilityIdentifier` (addressable axElement), a button
/// WITHOUT one (intentionally unaddressable — the documented SwiftUI contract),
/// a real UIKit control, and a SwiftUI markdown-link Text — the SwiftUI analogue
/// of an agreement row, where the links live inside ONE Text.
struct SwiftUIBoundaryView: View {
    @State private var taps = 0
    @State private var lastAction = "none"

    var body: some View {
        VStack(spacing: 24) {
            Text("SwiftUI boundary")
                .font(.title2)
                .accessibilityIdentifier("swiftui.title")

            Button("Sign In") { taps += 1 }
                .accessibilityIdentifier("login.signIn")

            // Deliberately unlabeled: must NOT be addressable by selector.
            Button("Unlabeled") { taps += 1 }

            Text("Taps: \(taps), last: \(lastAction)")
                .accessibilityIdentifier("swiftui.status")

            // Two links inside one Text — SwiftUI's agreement-row shape.
            Text(.init("Read the [Terms](reticle-sample://terms) and [Privacy](reticle-sample://privacy)"))
                .accessibilityIdentifier("swiftui.agreement")
                .environment(\.openURL, OpenURLAction { url in
                    lastAction = "opened \(url.host ?? url.absoluteString)"
                    Reticle.log("swiftui_link_clicked", metadata: ["url": .text(url.absoluteString)])
                    return .handled
                })

            UIKitButtonView { taps += 1 }
                .frame(width: 240, height: 50)
        }
        .padding()
    }
}

/// A concrete UIKit control embedded in SwiftUI, to exercise the view-tree walk
/// and in-process activation. Its touchUpInside increments the shared counter so
/// an `act activate --test-id embedded.uikitButton` is observable.
struct UIKitButtonView: UIViewRepresentable {
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle("Continue (UIKit)", for: .normal)
        button.backgroundColor = UIColor.systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.accessibilityIdentifier = "embedded.uikitButton"
        button.addTarget(context.coordinator, action: #selector(Coordinator.fire), for: .touchUpInside)
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {
        context.coordinator.onTap = onTap
    }

    final class Coordinator: NSObject {
        var onTap: () -> Void
        init(onTap: @escaping () -> Void) { self.onTap = onTap }
        @objc func fire() { onTap() }
    }
}
