// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Payvand",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Payvand", targets: ["Payvand"])
    ],
    targets: [
        .executableTarget(
            name: "Payvand",
            path: "Sources/Payvand"
        ),
        .testTarget(
            name: "PayvandTests",
            dependencies: ["Payvand"],
            path: "Tests/PayvandTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
