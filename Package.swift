// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Viber",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Viber", targets: ["Viber"]),
        .executable(name: "viber-ctl", targets: ["ViberCtl"])
    ],
    targets: [
        .target(name: "ViberCore"),
        /// Apple's private simulator frameworks, reached through the Objective-C runtime only.
        .target(name: "SimulatorBridge"),
        .executableTarget(name: "Viber", dependencies: ["ViberCore", "SimulatorBridge"]),
        .executableTarget(name: "ViberCtl", dependencies: ["ViberCore"]),
        .testTarget(name: "ViberCoreTests", dependencies: ["ViberCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SimulatorBridgeTests", dependencies: ["SimulatorBridge"])
    ]
)
