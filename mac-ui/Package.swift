// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "VoltAI",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VoltAI", targets: ["VoltAI"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "VoltAI",
            path: "Sources/VoltAI"
        )
    ]
)
