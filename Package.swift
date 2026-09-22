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
    dependencies: [
        // Pinned exactly: the notarization broker builds with
        // `--only-use-versions-from-resolved-file` against its own copy of
        // Package.resolved, so a floating requirement would only fail there.
        .package(url: "https://github.com/mxcl/AppUpdater.git", exact: "4.1.2"),
    ],
    targets: [
        .target(
            name: "OpenZombrKit",
            dependencies: [
                .product(name: "AppUpdater", package: "AppUpdater"),
            ],
            path: "Sources/OpenZombr",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "OpenZombrApp",
            dependencies: ["OpenZombrKit"],
            path: "Sources/OpenZombrApp",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OpenZombrTests",
            dependencies: ["OpenZombrKit"],
            path: "Tests/OpenZombrTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
