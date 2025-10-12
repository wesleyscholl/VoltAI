// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "BoltAI",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BoltAI", targets: ["BoltAI"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "BoltAI",
            path: "Sources/BoltAI"
        )
    ]
)
