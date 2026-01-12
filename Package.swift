// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CicareSdkCall",
    platforms: [
        .iOS(.v12),
        .macOS(.v13)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "CicareSdkCall",
            targets: ["CicareSdkCall"]),
    ],
    dependencies: [
        .package(url: "https://github.com/socketio/socket.io-client-swift", exact: "16.1.1"),
        .package(url: "https://github.com/stasel/WebRTC.git", branch: "latest"),
        .package(url: "https://github.com/daltoniam/Starscream.git", exact: "4.0.8"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", exact: "1.8.4")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "CicareSdkCall",
            dependencies: [
                .product(name: "SocketIO", package: "socket.io-client-swift"),
                .product(name: "WebRTC", package: "WebRTC"),
                .product(name: "Starscream", package: "Starscream"),
                .product(name: "CryptoSwift", package: "CryptoSwift")
            ],
            path: "./Sources/CicareSdkCall",
            resources: [
                .process("Media.xcassets")
            ]
        ),
        .testTarget(
            name: "CicareSdkCallTests",
            dependencies: [
                "CicareSdkCall",
                .product(name: "SocketIO", package: "socket.io-client-swift")
            ]
        ),
    ]
)
