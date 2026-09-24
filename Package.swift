// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CuztomSignal",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CuztomSignalCore", targets: ["CuztomSignalCore"]),
        .executable(name: "CuztomSignal", targets: ["CuztomSignalApp"]),
    ],
    targets: [
        .target(
            name: "CuztomSignalCore",
            path: "Sources/CuztomSignalCore"
        ),
        .executableTarget(
            name: "CuztomSignalApp",
            dependencies: ["CuztomSignalCore"],
            path: "XcodeApp/Sources"
        ),
        .testTarget(
            name: "CuztomSignalCoreTests",
            dependencies: ["CuztomSignalCore"],
            path: "Tests/CuztomSignalCoreTests"
        ),
    ]
)
