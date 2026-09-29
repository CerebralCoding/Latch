// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Latch",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "latch", targets: ["Latch"]),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "Latch",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "LatchTests",
            dependencies: ["Latch", "LatchTestWorkload"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .executableTarget(name: "LatchTestWorkload", path: "Tests/Support"),
    ],
)
