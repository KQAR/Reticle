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
        .library(name: "ReticleNetworkLane", targets: ["ReticleNetworkLane"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.25.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.2"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.1"),
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.19.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.1"),
        // The Swift implementation of reticle-protocol — shared with the iOS agent
        // so the host never re-ports models, PortMap, or the tree renderers.
        .package(path: "../reticle-swift"),
        // Loom's capture engine, consumed as an SPM library so the host network
        // lane doesn't maintain its own SwiftNIO proxy/MITM. Local path during
        // co-development (Loom lives beside the Reticle repo, so `../../Loom`
        // from this nested package); pin to a tag once Loom's API settles.
        .package(path: "../../Loom"),
    ],
    targets: [
        // Dependency-free foundation shared by the host and the network lane:
        // the JSON value type, the event envelope/post models, epoch-millis, and
        // the cross-boundary error. Kept below both so the lane never reaches up
        // into the daemon for a primitive.
        .target(
            name: "ReticleHostShared",
            path: "Sources/ReticleHostShared"
        ),
        // The host-side capture proxy + MITM + mock store, isolated behind the
        // `NetworkEventSink` protocol so it builds and tests without the daemon
        // (docs/roadmap.md: "proxy backend behind an interface"). ReticleHostCore
        // supplies the sink (EventStore) and the Hummingbird/CLI adapters.
        .target(
            name: "ReticleNetworkLane",
            dependencies: [
                "ReticleHostShared",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "X509", package: "swift-certificates"),
                // Loom-backed capture lane (LoomCaptureLane), gradually replacing
                // the in-tree NIO proxy. Both compile side-by-side during migration.
                // Path-dependency identity is the lowercased directory name ("loom").
                .product(name: "LoomProxyCore", package: "loom"),
                .product(name: "LoomSharedModels", package: "loom"),
            ],
            path: "Sources/ReticleNetworkLane"
        ),
        .target(
            name: "ReticleHostCore",
            dependencies: [
                "ReticleHostShared",
                "ReticleNetworkLane",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "ReticleProtocol", package: "reticle-swift"),
                "CReticleSimHID",
            ],
            path: "Sources/ReticleHostCore"
        ),
        // Private CoreSimulator HID input synthesis for the iOS simulator. Isolated
        // in a C target that dlopens the Xcode private frameworks at runtime, so a
        // missing/renamed symbol degrades to a clear error instead of a link failure.
        .target(
            name: "CReticleSimHID",
            path: "Sources/CReticleSimHID"
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
                "ReticleHostShared",
                "ReticleNetworkLane",
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
            ],
            path: "Tests/ReticleHostCoreTests"
        )
    ]
)
