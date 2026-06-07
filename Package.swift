// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpaceIndicator",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SpaceIndicator",
            path: "Sources/SpaceIndicator"
        )
    ]
)
