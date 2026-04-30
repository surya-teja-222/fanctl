// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "fanctl",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "fanctl", targets: ["fanctl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "fanctl",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/fanctl"
        ),
    ]
)
