// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "OpenZombr",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "OpenZombrKit",
            targets: ["OpenZombrKit"]
        ),
        .executable(
            name: "OpenZombr",
            targets: ["OpenZombrApp"]
        ),
    ],
    targets: [
        .target(
            name: "OpenZombrKit",
            path: "Sources/OpenZombr",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "OpenZombrApp",
            dependencies: ["OpenZombrKit"],
            path: "Sources/OpenZombrApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OpenZombrTests",
            dependencies: ["OpenZombrKit"],
            path: "Tests/OpenZombrTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
