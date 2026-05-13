// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AudioVisualizerCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Application", targets: ["Application"]),
        .library(name: "TPCircularBuffer", targets: ["TPCircularBuffer"]),
    ],
    targets: [
        .target(name: "Domain", path: "Sources/Domain"),
        .target(name: "Application", dependencies: ["Domain"], path: "Sources/Application"),
        .target(
            name: "TPCircularBuffer",
            path: "Vendor/TPCircularBuffer",
            sources: ["TPCircularBuffer.c"],
            publicHeadersPath: "include"
        ),
        .testTarget(name: "DomainTests", dependencies: ["Domain"], path: "Tests/DomainTests"),
        .testTarget(name: "ApplicationTests", dependencies: ["Domain", "Application"], path: "Tests/ApplicationTests"),
    ]
)
