// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "StrandExamples",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: ".."),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.32.2"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.12.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.22.0"),
        .package(url: "https://github.com/swift-otel/swift-otel.git", from: "1.1.0", traits: ["OTLPGRPC"]),
        .package(
            url: "https://github.com/swift-server/swift-service-lifecycle.git",
            from: "2.11.0"
        ),
    ],
    targets: [
        .executableTarget(
            name: "DevServer",
            dependencies: [
                .product(name: "Strand", package: "strand"),
                .product(name: "StrandServer", package: "strand"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "OTel", package: "swift-otel"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/DevServer"
        ),
        .executableTarget(
            name: "GroundwaterPipeline",
            dependencies: [
                .product(name: "Strand", package: "strand"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/GroundwaterPipeline"
        ),
        .executableTarget(
            name: "CIPipeline",
            dependencies: [
                .product(name: "Strand", package: "strand"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/CIPipeline"
        ),
        .executableTarget(
            name: "SmartBuilding",
            dependencies: [
                .product(name: "Strand", package: "strand"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/SmartBuilding"
        ),
        .executableTarget(
            name: "HackerNewsSummary",
            dependencies: [
                .product(name: "Strand", package: "strand"),
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "Sources/HackerNewsSummary"
        ),
    ],
    swiftLanguageModes: [.v6]
)
