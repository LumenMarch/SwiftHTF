// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftHTF",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(name: "SwiftHTF", targets: ["SwiftHTF"]),
        .library(name: "SwiftHTFUI", targets: ["SwiftHTFUI"]),
        .executable(name: "SwiftHTFDemo", targets: ["SwiftHTFDemo"]),
        .executable(name: "SwiftHTFSwiftUIDemo", targets: ["SwiftHTFSwiftUIDemo"]),
    ],
    targets: [
        .target(
            name: "SwiftHTF",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "SwiftHTFUI",
            dependencies: ["SwiftHTF"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "SwiftHTFDemo",
            dependencies: ["SwiftHTF"],
            path: "Examples/SwiftHTFDemo"
        ),
        .executableTarget(
            name: "SwiftHTFSwiftUIDemo",
            dependencies: ["SwiftHTF", "SwiftHTFUI"],
            path: "Examples/SwiftHTFSwiftUIDemo"
        ),
        .testTarget(
            name: "SwiftHTFTests",
            dependencies: ["SwiftHTF"]
        ),
        .testTarget(
            name: "SwiftHTFUITests",
            dependencies: ["SwiftHTFUI"]
        ),
    ]
)
