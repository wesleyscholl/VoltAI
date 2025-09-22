// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "BoltAIMacUI",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "BoltAIMacUI", targets: ["BoltAIMacUI"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "BoltAIMacUI",
            path: "Sources/BoltAIMacUI"
        )
    ]
)
