// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "SubscriptionCore", platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "SubscriptionCore", targets: ["SubscriptionCore"]),
        .executable(name: "SubscriptionChecks", targets: ["SubscriptionChecks"])],
    targets: [.target(name: "SubscriptionCore"),
        .executableTarget(name: "SubscriptionChecks", dependencies: ["SubscriptionCore"]),
        .testTarget(name: "SubscriptionCoreTests", dependencies: ["SubscriptionCore"])],
    swiftLanguageModes: [.v5])
