// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CuztomSignal",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CuztomSignalCore", targets: ["CuztomSignalCore"]),
        .executable(name: "CuztomSignal", targets: ["CuztomSignalApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sqlcipher/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(
            name: "CuztomSignalCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
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
