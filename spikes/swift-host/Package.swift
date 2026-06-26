// swift-tools-version:6.0
import PackageDescription

// Spike: prove a Swift host can drive the Kotlin reticle-android-helper across a
// long-lived stdio RPC boundary. NOT a product target — it lives under spikes/
// and is excluded from the Gradle build. See docs/roadmap.md, "Direction: Swift
// host + per-platform helpers".
let package = Package(
    name: "reticle-swift-host-spike",
    targets: [
        .executableTarget(name: "ReticleSwiftHostSpike", path: "Sources/ReticleSwiftHostSpike")
    ]
)
