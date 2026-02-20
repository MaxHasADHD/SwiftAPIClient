// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftAPIClient",
    platforms: [
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "SwiftAPIClient",
            targets: ["SwiftAPIClient"]),
    ],
    targets: [
        .target(
            name: "SwiftAPIClient",
            dependencies: [],
            path: "Sources/SwiftAPIClient"
        ),
        .testTarget(
            name: "SwiftAPIClientTests",
            dependencies: ["SwiftAPIClient"]
        ),
    ],
    swiftLanguageModes: [.version("6.0")]
)
