// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Trail",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TrailCore", targets: ["TrailCore"]),
        .executable(name: "trail", targets: ["trail"]),
    ],
    targets: [
        .target(
            name: "TrailCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "trail", dependencies: ["TrailCore"]),
        .testTarget(name: "TrailCoreTests", dependencies: ["TrailCore"]),
    ],
    swiftLanguageModes: [.v5]
)
