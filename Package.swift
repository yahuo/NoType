// swift-tools-version: 6.1

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
        .target(
            name: "NoTypeEditorCore"
        ),
        .executableTarget(
            name: "NoTypeEditor",
            dependencies: ["NoTypeEditorCore"]
        ),
        .testTarget(
            name: "NoTypeTests",
            dependencies: ["NoType", "NoTypeEditorCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
