// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacPulse",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacPulseCore", targets: ["MacPulseCore"]),
        .executable(name: "MacPulse", targets: ["MacPulse"]),
    ],
    targets: [
        .target(
            name: "MacPulseNative",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MacPulseCore",
            dependencies: ["MacPulseNative"]
        ),
        .executableTarget(
            name: "MacPulse",
            dependencies: ["MacPulseCore"]
        ),
        .testTarget(
            name: "MacPulseCoreTests",
            dependencies: ["MacPulseCore"]
        ),
    ]
)
