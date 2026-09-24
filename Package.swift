// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CuztomSignal",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CuztomSignalCore", targets: ["CuztomSignalCore"]),
    ],
    targets: [
        .target(
            name: "CuztomSignalCore",
            path: "Sources/CuztomSignalCore"
        ),
        .testTarget(
            name: "CuztomSignalCoreTests",
            dependencies: ["CuztomSignalCore"],
            path: "Tests/CuztomSignalCoreTests"
        ),
    ]
)
