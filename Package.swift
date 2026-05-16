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
        .library(name: "SwiftHTFCharts", targets: ["SwiftHTFCharts"]),
        .executable(name: "SwiftHTFDemo", targets: ["SwiftHTFDemo"]),
        .executable(name: "SwiftHTFSwiftUIDemo", targets: ["SwiftHTFSwiftUIDemo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        // 文档生成：`swift package generate-documentation --target SwiftHTF`
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "SwiftHTF",
            dependencies: ["Yams"],
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
        .target(
            name: "SwiftHTFCharts",
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
            dependencies: ["SwiftHTF", "SwiftHTFUI", "SwiftHTFCharts"],
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
        .testTarget(
            name: "SwiftHTFChartsTests",
            dependencies: ["SwiftHTFCharts"]
        ),
    ]
)
