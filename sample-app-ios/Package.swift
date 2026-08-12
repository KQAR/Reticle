// swift-tools-version:6.2
import PackageDescription

// sample-app-ios — the iOS demo that proves the round trip, the analogue of the
// Android `sample-app`. `SampleApp` links `ReticleKit` (the linked path) and calls
// `Reticle.start()`. `SampleAppNoAgent` is the honest injection target: identical
// UI, but it does NOT link ReticleKit, so `reticle --target ios app inject` must
// bring the runtime up on its own. Both are built into .app bundles by
// scripts/build-sample-ios.sh (SwiftPM alone doesn't emit .app bundles).
// Swift 6.2 strict concurrency. Unlike the agent and the host, the sample apps
// are pure SwiftUI, so they take the 6.2 "approachable concurrency" default:
// every declaration is `@MainActor` unless it says otherwise, which is what a UI
// target actually is. Anything that must run off the main actor has to say so —
// the inverse of annotating almost every type with `@MainActor` by hand.
let strictConcurrency: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "sample-app-ios",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .executable(name: "SampleApp", targets: ["SampleApp"]),
        .executable(name: "SampleAppNoAgent", targets: ["SampleAppNoAgent"]),
    ],
    dependencies: [
        .package(path: "../reticle-agent/ios"),
        // Real Lottie animation view for the native-lottie-dialog scenario.
        .package(url: "https://github.com/airbnb/lottie-ios.git", from: "4.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "SampleApp",
            dependencies: [
                // Path-dependency identity is the directory basename ("ios").
                .product(name: "ReticleKit", package: "ios"),
                .product(name: "Lottie", package: "lottie-ios"),
            ],
            path: "Sources/SampleApp",
            // lottie_anim.json (native + web) and lottie_light.min.js (web,
            // inlined offline) — read at runtime via Bundle.module. The custom
            // .app assembly in build-sample-ios.sh copies the generated resource
            // bundle in alongside the binary.
            resources: [
                .process("Resources"),
            ],
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "SampleAppNoAgent",
            path: "Sources/SampleAppNoAgent",
            swiftSettings: strictConcurrency
        ),
    ]
)
