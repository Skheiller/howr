// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Howr",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Howr",
            path: "Sources/Howr",
            swiftSettings: [.unsafeFlags(["-Osize"])]
        ),
        .testTarget(name: "HowrTests", dependencies: ["Howr"], path: "Tests/HowrTests"),
    ]
)
