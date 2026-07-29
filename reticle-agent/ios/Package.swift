// swift-tools-version:6.1
import PackageDescription

// reticle-agent/ios — the in-process iOS agent. Mirrors the Android AAR
// (`reticle-agent/android`): a loopback HTTP server, UIKit view-tree capture, a
// SwiftUI accessibility bridge (emits `axElement` nodes), allowlist mutation, an
// in-process screenshot, and dual auto-start. It emits `platform="ios"` protocol
// JSON via the shared `ReticleProtocol`. Built by SwiftPM, invisible to Gradle.
//
// Products:
//   - ReticleKit         : link this into an app (the "linked" path), call Reticle.start()
//   - ReticleInjection   : a dynamic library for the DYLD-injection path
//                          (DYLD_INSERT_LIBRARIES); a C constructor calls the
//                          exported `ReticleInjectorStart` on load.
let package = Package(
    name: "reticle-agent-ios",
    platforms: [
        .iOS(.v15),
        .tvOS(.v15),
        // Declared only so the package graph resolves against ReticleProtocol's
        // macOS floor; the UIKit code is never built for macOS.
        .macOS(.v13),
    ],
    products: [
        .library(name: "ReticleKit", targets: ["ReticleKit"]),
        .library(name: "ReticleInjection", type: .dynamic, targets: ["ReticleInjection"]),
    ],
    dependencies: [
        .package(path: "../../reticle-swift"),
    ],
    targets: [
        .target(
            name: "ReticleKit",
            dependencies: [
                .product(name: "ReticleProtocol", package: "reticle-swift"),
            ],
            path: "Sources/ReticleKit"
        ),
        .target(
            name: "CReticleBootstrap",
            path: "Sources/CReticleBootstrap"
        ),
        .target(
            name: "ReticleInjection",
            dependencies: ["ReticleKit", "CReticleBootstrap"],
            path: "Sources/ReticleInjection"
        ),
        // The agent's unit tests. UIKit-only, so they cannot run under a plain
        // `swift test` on the host: drive them with scripts/test-ios-agent.sh,
        // which runs `xcodebuild test` against a booted iOS simulator (CI does
        // the same). They cover the capture-side logic that is reachable without
        // a host app — text geometry, the region channels, the Lottie
        // reflection, HTTP framing — not the whole-screen walk, which needs a
        // real scene.
        .testTarget(
            name: "ReticleKitTests",
            dependencies: [
                "ReticleKit",
                .product(name: "ReticleProtocol", package: "reticle-swift"),
            ],
            path: "Tests/ReticleKitTests"
        ),
    ]
)
