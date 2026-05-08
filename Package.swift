// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "strand",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "Strand", targets: ["Strand"]),
        .library(name: "StrandServer", targets: ["StrandServer"]),
    ],
    dependencies: [
        // Pinned to commit 820771e which includes the runTimer continuation leak fix
        // (PR #641: pool idle-timer reschedule dropped CheckedContinuation).
        // Revert to `from: "1.x.x"` once a release including that patch is cut.
        .package(url: "https://github.com/vapor/postgres-nio.git", revision: "820771e"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.99.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.12.0"),
        .package(
            url: "https://github.com/swift-server/swift-service-lifecycle.git",
            from: "2.11.0"
        ),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.22.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.10.1"),
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.4.1"),
        .package(
            url: "https://github.com/swift-otel/swift-otel-semantic-conventions.git",
            from: "1.34.2"
        ),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "Strand",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
                .product(
                    name: "OTelSemanticConventions",
                    package: "swift-otel-semantic-conventions"
                ),
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
            ],
            swiftSettings: [
                // Non-isolated async functions run on a generic executor, not the caller's actor.
                // SE-0461
                .enableUpcomingFeature("NonIsolatedNonSendingByDefault"),
                // Imports are internal by default — prevents leaking internals to callers.
                // SE-0409
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .target(
            name: "StrandServer",
            dependencies: [
                "Strand",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            resources: [
                .copy("Resources/ui")
            ],
            swiftSettings: [
                .enableUpcomingFeature("InternalImportsByDefault")
            ]
        ),
        .testTarget(
            name: "StrandTests",
            dependencies: [
                "Strand",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "Tracing", package: "swift-distributed-tracing"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
