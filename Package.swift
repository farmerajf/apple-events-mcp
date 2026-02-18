// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleEventsMCP",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "apple-events-mcp",
            targets: ["AppleEventsMCP"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", from: "0.26.0")
    ],
    targets: [
        .executableTarget(
            name: "AppleEventsMCP",
            dependencies: [
                .product(name: "FlyingFox", package: "FlyingFox")
            ],
            path: "Sources"
        )
    ]
)
