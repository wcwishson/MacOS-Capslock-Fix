// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MacInputTweak",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "MacInputTweak", targets: ["MacInputTweak"]),
    ],
    targets: [
        .executableTarget(
            name: "MacInputTweak",
            path: "Sources/MacInputTweak"
        ),
    ]
)
