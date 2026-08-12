// swift-tools-version:6.2
import PackageDescription

// reticle-host — the Swift host CLI. It drives Android through the Kotlin
// `reticle helper` over the JSONL RPC contract (reticle-protocol/helper-rpc.md);
// it owns no device-specific code itself. This is the first real slice of the
// "Swift host + per-platform helpers" decision (docs/roadmap.md). The
// Hummingbird-backed serve event-bus skeleton and read-only Web panel live here;
// the capture proxy remains a later phase.

// Swift 6.2 strict concurrency — see reticle-swift/Package.swift for why these
// three and not more. The host is nonisolated by default on purpose: it is a CLI
// and a Hummingbird server, so its work belongs off the main actor.
let strictConcurrency: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "reticle-host",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "ReticleHost", targets: ["ReticleHost"]),
        .library(name: "ReticleHostCore", targets: ["ReticleHostCore"]),
        .library(name: "ReticleNetworkLane", targets: ["ReticleNetworkLane"]),
        .library(name: "ReticleHostIos", targets: ["ReticleHostIos"]),
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
        // lane doesn't maintain its own SwiftNIO proxy/MITM.
        .package(url: "https://github.com/KQAR/Loom.git", exact: "0.0.12"),
        // The standard-library-adjacent process runner. The host shells out on
        // every iOS path (simctl, devicectl, xcodebuild, iproxy), and each site
        // used to hand-roll the spawn + concurrent two-pipe drain that avoids the
        // 64KB stderr deadlock. This owns that once.
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", exact: "1.0.0"),
    ],
    targets: [
        // Dependency-free foundation shared by the host and the network lane:
        // the JSON value type, the event envelope/post models, epoch-millis, and
        // the cross-boundary error. Kept below both so the lane never reaches up
        // into the daemon for a primitive.
        .target(
            name: "ReticleHostShared",
            dependencies: [
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            path: "Sources/ReticleHostShared",
            swiftSettings: strictConcurrency
        ),
        // The host-side capture proxy + MITM + mock store, isolated behind the
        // `NetworkEventSink` protocol so it builds and tests without the daemon
        // (docs/roadmap.md: "the capture engine sits behind one sink"). ReticleHostCore
        // supplies the sink (EventStore) and the Hummingbird/CLI adapters.
        .target(
            name: "ReticleNetworkLane",
            dependencies: [
                "ReticleHostShared",
                // Transport (NIO proxy, MITM, CA) is Loom's engine now; this target
                // only normalizes captured flows into session events, so it needs no
                // NIO/certificate deps of its own. Path-dependency identity is the
                // lowercased directory name ("loom").
                .product(name: "LoomProxyCore", package: "loom"),
                .product(name: "LoomSharedModels", package: "loom"),
            ],
            path: "Sources/ReticleNetworkLane",
            swiftSettings: strictConcurrency
        ),
        // The iOS platform backend: simctl/devicectl device control, direct loopback
        // HTTP to the in-process agent, the wait/scroll-to/verify loops, and private
        // CoreSimulator HID input. It implements `HelperCalling` (in the shared layer)
        // and depends on nothing above it — no daemon, no CLI — so the compiler now
        // enforces what was previously only true by habit: the daemon never reaches
        // into platform code, and a platform backend never reaches up into the CLI.
        .target(
            name: "ReticleHostIos",
            dependencies: [
                "ReticleHostShared",
                .product(name: "ReticleProtocol", package: "reticle-swift"),
                "CReticleSimHID",
            ],
            path: "Sources/ReticleHostIos",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "ReticleHostCore",
            dependencies: [
                "ReticleHostShared",
                "ReticleNetworkLane",
                "ReticleHostIos",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "ReticleProtocol", package: "reticle-swift"),
            ],
            path: "Sources/ReticleHostCore",
            swiftSettings: strictConcurrency
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
            path: "Sources/ReticleHost",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "ReticleHostCoreTests",
            dependencies: [
                "ReticleHostCore",
                "ReticleHostShared",
                "ReticleNetworkLane",
                "ReticleHostIos",
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                // Lets the action-trace diff contract test build `Snapshot`s from the
                // shared fixture, so the Swift port is pinned against the same table
                // the Kotlin port reads.
                .product(name: "ReticleProtocol", package: "reticle-swift"),
                // Lets the capture-lane tests synthesize Loom `Flow`s directly, so the
                // normalization from flow to `network.*` event is pinned without a live
                // proxy — the WebSocket frame path especially, which a socket-less
                // e2e can otherwise only reach by accident.
                .product(name: "LoomSharedModels", package: "loom"),
            ],
            path: "Tests/ReticleHostCoreTests",
            swiftSettings: strictConcurrency
        )
    ]
)
