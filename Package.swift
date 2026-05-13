// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AudioVisualizerCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Application", targets: ["Application"]),
    ],
    targets: [
        .target(name: "Domain", path: "Sources/Domain"),
        .target(name: "Application", dependencies: ["Domain"], path: "Sources/Application"),
        .testTarget(name: "DomainTests", dependencies: ["Domain"], path: "Tests/DomainTests"),
        .testTarget(name: "ApplicationTests", dependencies: ["Domain", "Application"], path: "Tests/ApplicationTests"),
    ]
)
