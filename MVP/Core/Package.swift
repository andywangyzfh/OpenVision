// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenVisionCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "OpenVisionCore", targets: ["OpenVisionCore"]),
        .executable(name: "CoreChecks", targets: ["CoreChecks"])
    ],
    targets: [
        .target(name: "OpenVisionCore"),
        .executableTarget(name: "CoreChecks", dependencies: ["OpenVisionCore"], path: "Checks"),
        .testTarget(name: "OpenVisionCoreTests", dependencies: ["OpenVisionCore"])
    ]
)
