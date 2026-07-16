import SwiftUI
import UIKit

// The injection test target: identical UI to SampleApp, but it does NOT link
// ReticleKit and never calls Reticle.start(). `reticle --target ios app inject`
// must load libReticleInjection.dylib via DYLD and bring the runtime up itself —
// the honest analogue of the Android `noagent` flavor.
@main
struct SampleAppNoAgent: App {
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
            Text("Reticle iOS Sample (noagent)")
                .font(.title2)
                .accessibilityIdentifier("title")

            Button("Sign In") { taps += 1 }
                .accessibilityIdentifier("login.signIn")

            Button("Unlabeled") { taps += 1 }

            Text("Taps: \(taps)")
                .accessibilityIdentifier("tapCount")

            UIKitButtonView()
                .frame(width: 240, height: 50)
        }
        .padding()
    }
}

struct UIKitButtonView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle("Continue (UIKit)", for: .normal)
        button.backgroundColor = UIColor.systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 8
        button.accessibilityIdentifier = "checkout.payButton"
        return button
    }

    func updateUIView(_ uiView: UIButton, context: Context) {}
}
