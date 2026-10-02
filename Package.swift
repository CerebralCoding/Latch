// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

#if !os(macOS) || !arch(arm64)
    #error("Latch requires Apple Silicon and macOS 26 or newer")
#endif

let package = Package(
    name: "Latch",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "latch", targets: ["Latch"]),
        .library(name: "LatchCheckpoint", targets: ["LatchCheckpoint"]),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "Latch",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ],
        ),
        .testTarget(
            name: "LatchTests",
            dependencies: ["Latch", "LatchTestWorkload", "LatchRelease"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency")
            ],
        ),
        .target(name: "LatchCheckpoint"),
        .executableTarget(name: "LatchTestWorkload", dependencies: ["LatchCheckpoint"], path: "Tests/Support"),
        .executableTarget(name: "LatchRelease"),
    ],
)
