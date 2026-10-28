// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Pulsar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Pulsar",
            path: "Sources/Pulsar",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        )
    ]
)
