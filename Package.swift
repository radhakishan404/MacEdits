// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MacEdits",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "MacEdits"
        ),
        .testTarget(
            name: "MacEditsTests",
            dependencies: ["MacEdits"]
        ),
    ]
)
