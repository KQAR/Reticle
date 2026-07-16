// swift-tools-version:6.1
import PackageDescription

// reticle-swift — the Swift implementation of `reticle-protocol`. This is the
// parallel of the Kotlin `reticle-core`: Codable models with the same
// omit-defaults JSON shape, the `SemanticTree` / `CompactObservation`
// derivations, `PortMap`, and the host-side text renderers. Both the in-process
// iOS agent (`reticle-agent/ios`) and the Swift host (`reticle-host`) depend on
// this package so the protocol is never re-ported. Outside the Gradle build.
let package = Package(
    name: "reticle-swift",
    platforms: [
        .macOS(.v13),
        .iOS(.v15),
        .tvOS(.v15),
    ],
    products: [
        .library(name: "ReticleProtocol", targets: ["ReticleProtocol"]),
    ],
    targets: [
        .target(
            name: "ReticleProtocol",
            path: "Sources/ReticleProtocol"
        ),
        .testTarget(
            name: "ReticleProtocolTests",
            dependencies: ["ReticleProtocol"],
            path: "Tests/ReticleProtocolTests"
        ),
    ]
)
