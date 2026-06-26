// swift-tools-version:6.0
import PackageDescription

// reticle-host — the Swift host CLI. It drives Android through the Kotlin
// `reticle helper` over the JSONL RPC contract (reticle-protocol/helper-rpc.md);
// it owns no device-specific code itself. This is the first real slice of the
// "Swift host + per-platform helpers" direction (docs/roadmap.md). The daemon /
// Web panel / proxy are later phases and are NOT part of this target yet.
let package = Package(
    name: "reticle-host",
    targets: [
        .executableTarget(
            name: "ReticleHost",
            path: "Sources/ReticleHost"
        )
    ]
)
