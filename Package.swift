// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MemoryBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MemoryBar", targets: ["MemoryBar"])
    ],
    targets: [
        .executableTarget(
            name: "MemoryBar",
            path: "Sources/MemoryBar"
        ),
        .testTarget(
            name: "MemoryBarTests",
            dependencies: ["MemoryBar"],
            path: "Tests/MemoryBarTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
