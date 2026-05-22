import CompilerPluginSupport
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
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.33.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.100.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.12.1"),
        .package(
            url: "https://github.com/swift-server/swift-service-lifecycle.git",
            from: "2.11.0"
        ),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.24.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.11.0"),
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.4.1"),
        .package(
            url: "https://github.com/swift-otel/swift-otel-semantic-conventions.git",
            from: "1.39.0"
        ),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.5.1"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.1.4"),
        .package(url: "https://github.com/adam-fowler/compress-nio.git", from: "1.4.2"),
        .package(url: "https://github.com/swift-extras/swift-extras-base64.git", from: "1.0.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.1"),
    ],
    targets: [
        .macro(
            name: "StrandMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "Strand",
            dependencies: [
                "StrandMacrosPlugin",
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
                .product(name: "CompressNIO", package: "compress-nio"),
                .product(name: "ExtrasBase64", package: "swift-extras-base64"),
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
        .testTarget(
            name: "StrandMacrosTests",
            dependencies: [
                "Strand",
                "StrandMacrosPlugin",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftBasicFormat", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
