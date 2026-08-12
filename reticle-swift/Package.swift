// swift-tools-version:6.2
import PackageDescription

// reticle-swift — the Swift implementation of `reticle-protocol`. This is the
// parallel of the Kotlin `reticle-core`: Codable models with the same
// omit-defaults JSON shape, the `SemanticTree` / `CompactObservation`
// derivations, `PortMap`, and the host-side text renderers. Both the in-process
// iOS agent (`reticle-agent/ios`) and the Swift host (`reticle-host`) depend on
// this package so the protocol is never re-ported. Outside the Gradle build.

// Swift 6.2 with concurrency checking turned all the way up, applied to every
// target in the repo's four packages. Language mode 6 is what makes strict
// concurrency an error rather than a warning; the two upcoming features are the
// Swift 7 defaults, adopted now so the migration is already paid for:
//
//   NonisolatedNonsendingByDefault (SE-0461) — a `nonisolated async` function
//     runs on the caller's actor instead of hopping to the generic executor, so
//     calling one from `@MainActor` no longer silently requires Sendable args.
//   InferIsolatedConformances (SE-0470) — a `@MainActor` type's conformances are
//     inferred `@MainActor` instead of forcing `nonisolated` shims.
let strictConcurrency: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "reticle-swift",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
    ],
    products: [
        .library(name: "ReticleProtocol", targets: ["ReticleProtocol"]),
    ],
    targets: [
        .target(
            name: "ReticleProtocol",
            path: "Sources/ReticleProtocol",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "ReticleProtocolTests",
            dependencies: ["ReticleProtocol"],
            path: "Tests/ReticleProtocolTests",
            swiftSettings: strictConcurrency
        ),
    ]
)
