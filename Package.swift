// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AVRecorderKit",
    platforms: [
       .macOS(.v10_15)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "AVRecorderKit",
            targets: ["AVRecorderKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sunlubo/SwiftFFmpeg.git", branch: "master"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "AVRecorderKit",
            dependencies: [
                .product(name: "SwiftFFmpeg", package: "SwiftFFmpeg"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "AVRecorderKitTests",
            dependencies: [
                "AVRecorderKit"
            ]
        ),
    ]
)
