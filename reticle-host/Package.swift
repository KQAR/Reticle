// swift-tools-version:6.1
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
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.2"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.1"),
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.19.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.1"),
    ],
    targets: [
        .target(
            name: "ReticleHostCore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "X509", package: "swift-certificates"),
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
            dependencies: [
                "ReticleHostCore",
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            path: "Tests/ReticleHostCoreTests"
        )
    ]
)
