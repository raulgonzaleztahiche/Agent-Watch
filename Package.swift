// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentWatch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agentwatch-cli", targets: ["agentwatch-cli"]),
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
    ]
)
