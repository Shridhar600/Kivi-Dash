// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KiviStats",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KiviCore", targets: ["KiviCore"])
    ],
    targets: [
        .target(name: "KiviCore"),
        .executableTarget(name: "KiviStatsApp", dependencies: ["KiviCore"]),
        .testTarget(name: "KiviCoreTests", dependencies: ["KiviCore"]),
    ],
    swiftLanguageModes: [.v6]
)