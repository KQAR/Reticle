// swift-tools-version:6.1
import PackageDescription

// sample-app-ios — the iOS demo that proves the round trip, the analogue of the
// Android `sample-app`. `SampleApp` links `ReticleKit` (the linked path) and calls
// `Reticle.start()`. `SampleAppNoAgent` is the honest injection target: identical
// UI, but it does NOT link ReticleKit, so `reticle --target ios app inject` must
// bring the runtime up on its own. Both are built into .app bundles by
// scripts/build-sample-ios.sh (SwiftPM alone doesn't emit .app bundles).
let package = Package(
    name: "sample-app-ios",
    platforms: [
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .executable(name: "SampleApp", targets: ["SampleApp"]),
        .executable(name: "SampleAppNoAgent", targets: ["SampleAppNoAgent"]),
    ],
    dependencies: [
        .package(path: "../reticle-agent/ios"),
    ],
    targets: [
        .executableTarget(
            name: "SampleApp",
            dependencies: [
                // Path-dependency identity is the directory basename ("ios").
                .product(name: "ReticleKit", package: "ios"),
            ],
            path: "Sources/SampleApp"
        ),
        .executableTarget(
            name: "SampleAppNoAgent",
            path: "Sources/SampleAppNoAgent"
        ),
    ]
)
