// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "VoltAI",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VoltAI", targets: ["VoltAI"]),
        .library(name: "VoltAICore", targets: ["VoltAICore"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "VoltAICore",
            path: "Sources/VoltAICore"
        ),
        .executableTarget(
            name: "VoltAI",
            dependencies: ["VoltAICore"],
            path: "Sources/VoltAI"
        ),
        .testTarget(
            name: "VoltAITests",
            dependencies: ["VoltAICore"],
            path: "Tests/VoltAITests"
        ),
    ]
)
