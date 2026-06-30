// swift-tools-version:6.0
import PackageDescription

// reticle-host — the Swift host CLI. It drives Android through the Kotlin
// `reticle helper` over the JSONL RPC contract (reticle-protocol/helper-rpc.md);
// it owns no device-specific code itself. This is the first real slice of the
// "Swift host + per-platform helpers" direction (docs/roadmap.md). The
// Hummingbird-backed serve event-bus skeleton and read-only Web panel live here;
// the capture proxy remains a later phase.
let package = Package(
    name: "reticle-host",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "ReticleHost", targets: ["ReticleHost"]),
        .library(name: "ReticleHostCore", targets: ["ReticleHostCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.25.0"),
    ],
    targets: [
        .target(
            name: "ReticleHostCore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/ReticleHostCore"
        ),
        .executableTarget(
            name: "ReticleHost",
            dependencies: ["ReticleHostCore"],
            path: "Sources/ReticleHost"
        ),
        .testTarget(
            name: "ReticleHostCoreTests",
            dependencies: ["ReticleHostCore"],
            path: "Tests/ReticleHostCoreTests"
        )
    ]
)
