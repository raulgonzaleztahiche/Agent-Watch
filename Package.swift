// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentWatch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agentwatch-cli", targets: ["agentwatch-cli"]),
        .executable(name: "AgentWatchApp", targets: ["AgentWatchApp"]),
    ],
    targets: [
        // Domain: model and port. No file system, no SQLite.
        .target(name: "AgentCore"),
        // Driven adapters that read each tool's local data.
        .target(
            name: "Adapters",
            dependencies: ["AgentCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "agentwatch-cli",
            dependencies: ["AgentCore", "Adapters"]
        ),
        // Menu bar UI: thin glue over AgentCore, no rules of its own.
        .executableTarget(
            name: "AgentWatchApp",
            dependencies: ["AgentCore", "Adapters"]
        ),
        // Fixtures are synthetic: they mirror the real formats, never copy real transcripts.
        .testTarget(
            name: "AgentWatchTests",
            dependencies: ["AgentCore", "Adapters"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
