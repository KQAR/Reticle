// swift-tools-version:6.0
import PackageDescription

// reticle-host — the Swift host CLI. It drives Android through the Kotlin
// `reticle helper` over the JSONL RPC contract (reticle-protocol/helper-rpc.md);
// it owns no device-specific code itself. This is the first real slice of the
// "Swift host + per-platform helpers" direction (docs/roadmap.md). The serve
// event-bus skeleton lives here; the Web panel and proxy remain later phases.
let package = Package(
    name: "reticle-host",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "ReticleHost", targets: ["ReticleHost"]),
        .library(name: "ReticleHostCore", targets: ["ReticleHostCore"]),
    ],
    targets: [
        .target(
            name: "ReticleHostCore",
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
