// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PocketAgentRemote",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agentprobe", targets: ["AgentProbe"]),
        .executable(name: "coresmoke", targets: ["AgentCoreSmoke"]),
        .library(name: "PocketAgentCore", targets: ["PocketAgentCore"]),
    ],
    targets: [
        // Phase 1+ : controller core. Adapter-independent, so it is unaffected by how the
        // Codex / Claude desktop adapters end up being implemented.
        .target(
            name: "PocketAgentCore",
            path: "Sources/PocketAgentCore",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("GameController"),
                .linkedFramework("IOKit"),
            ]
        ),
        // Phase 0 research tool, kept as-is.
        .executableTarget(
            name: "AgentProbe",
            path: "Sources/AgentProbe",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("GameController"),
                .linkedFramework("IOKit"),
            ]
        ),
        // Phase 1 hardware verification: runs the real chain against a real controller.
        .executableTarget(
            name: "AgentCoreSmoke",
            dependencies: ["PocketAgentCore"],
            path: "Sources/AgentCoreSmoke",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "PocketAgentCoreTests",
            dependencies: ["PocketAgentCore"],
            path: "Tests/PocketAgentCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
