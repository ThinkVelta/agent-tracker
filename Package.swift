// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentTracker",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "AgentTracker",
            path: "Sources/AgentTracker"
        )
    ]
)
