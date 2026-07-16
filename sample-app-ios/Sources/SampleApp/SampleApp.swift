import SwiftUI
import UIKit
import ReticleKit

// The linked demo. It starts the agent explicitly at launch. The UI mixes a
// SwiftUI button that carries an `.accessibilityIdentifier` (so it surfaces as an
// addressable `axElement`), a SwiftUI button with NO identifier (so it stays
// intentionally unaddressable — the documented SwiftUI boundary), and a real
// UIKit button (so the view-tree walk has a concrete node to resolve).
@main
struct SampleApp: App {
    init() {
        Reticle.start()
        Reticle.log("SampleApp launched")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var taps = 0

    var body: some View {
        VStack(spacing: 24) {
            Text("Reticle iOS Sample")
                .font(.title2)
                .accessibilityIdentifier("title")

            Button("Sign In") { taps += 1 }
                .accessibilityIdentifier("login.signIn")

            // Deliberately unlabeled: must NOT be addressable by selector.
            Button("Unlabeled") { taps += 1 }

            Text("Taps: \(taps)")
                .accessibilityIdentifier("tapCount")

            UIKitButtonView { taps += 1 }
                .frame(width: 240, height: 50)
        }
        .padding()
    }
}

/// A concrete UIKit control embedded in SwiftUI, to exercise the view-tree walk
/// and in-process activation. Its touchUpInside increments the shared counter so
/// an `act activate --test-id checkout.payButton` is observable.
struct UIKitButtonView: UIViewRepresentable {
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle("Continue (UIKit)", for: .normal)
        button.backgroundColor = UIColor.systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.accessibilityIdentifier = "checkout.payButton"
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
