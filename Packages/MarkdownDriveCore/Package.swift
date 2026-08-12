// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "MarkdownDriveCore",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "MarkdownDriveCore",
            targets: ["MarkdownDriveCore"]
        ),
    ],
    targets: [
        .target(name: "MarkdownDriveCore"),
        .testTarget(
            name: "MarkdownDriveCoreTests",
            dependencies: ["MarkdownDriveCore"]
        ),
    ]
)
