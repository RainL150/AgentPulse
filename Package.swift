// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentPulse",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AgentPulse", targets: ["AgentPulse"])
    ],
    targets: [
        .executableTarget(
            name: "AgentPulse",
            path: "ClaudeMonitor"
        )
    ]
)
