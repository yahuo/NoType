// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "NoType",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "NoType"
        ),
        .testTarget(
            name: "NoTypeTests",
            dependencies: ["NoType"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
