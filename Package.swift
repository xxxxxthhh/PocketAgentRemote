// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PocketAgentRemote",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agentprobe", targets: ["AgentProbe"])
    ],
    targets: [
        .executableTarget(
            name: "AgentProbe",
            path: "Sources/AgentProbe",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("GameController"),
                .linkedFramework("IOKit"),
            ]
        )
    ]
)
