import Foundation

/// Persisted settings (spec §16).
public struct AppConfig: Codable, Equatable, Sendable {
    public var version: Int
    public var activeProfile: ToolProfile

    // Gesture timing (spec §6.2 / §18).
    public var tapMaxMs: Double
    public var holdMs: Double

    // Security (spec §17).
    public var macrosEnabled: Bool
    public var requireAllowedFrontmostApp: Bool
    public var allowedBundleIDs: [String]

    /// Per-action keystroke overrides, keyed by `AgentAction.rawValue`.
    ///
    /// This is how the *class C* actions become usable: `toggleFastMode` and `forkThread` ship no
    /// default accelerator in the Codex desktop app, so the user binds a key once inside Codex's own
    /// Settings → Keyboard Shortcuts and records the same key here.
    public var actionKeyOverrides: [String: KeyBinding]

    public struct KeyBinding: Codable, Equatable, Sendable {
        public var key: Key
        public var modifiers: [ModifierKey]

        public init(key: Key, modifiers: [ModifierKey] = []) {
            self.key = key
            self.modifiers = modifiers
        }

        public var stroke: KeyStroke {
            KeyStroke(key, modifiers: Set(modifiers))
        }
    }

    public init(
        version: Int = AppConfig.currentVersion,
        activeProfile: ToolProfile = .genericTerminal,
        tapMaxMs: Double = 220,
        holdMs: Double = 450,
        macrosEnabled: Bool = false,
        requireAllowedFrontmostApp: Bool = true,
        allowedBundleIDs: [String] = AppConfig.defaultAllowedBundleIDs,
        actionKeyOverrides: [String: KeyBinding] = [:]
    ) {
        self.version = version
        self.activeProfile = activeProfile
        self.tapMaxMs = tapMaxMs
        self.holdMs = holdMs
        self.macrosEnabled = macrosEnabled
        self.requireAllowedFrontmostApp = requireAllowedFrontmostApp
        self.allowedBundleIDs = allowedBundleIDs
        self.actionKeyOverrides = actionKeyOverrides
    }

    public static let currentVersion = 1

    public static let defaultAllowedBundleIDs = [
        "com.openai.codex",                    // Codex desktop app
        "com.anthropic.claudefordesktop",      // Claude desktop app
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode",
    ]

    public var gestureConfiguration: GestureConfiguration {
        GestureConfiguration(tapMaxMs: tapMaxMs, holdMs: holdMs)
    }

    public var guardPolicy: GuardPolicy {
        GuardPolicy(
            allowedBundleIDs: Set(allowedBundleIDs),
            requireAllowedFrontmostApp: requireAllowedFrontmostApp,
            macrosEnabled: macrosEnabled
        )
    }

    public var overrides: [AgentAction: KeyStroke] {
        var result: [AgentAction: KeyStroke] = [:]
        for (rawAction, binding) in actionKeyOverrides {
            guard let action = AgentAction(rawValue: rawAction) else { continue }
            result[action] = binding.stroke
        }
        return result
    }
}

/// Reads and writes `AppConfig` as JSON.
///
/// Never overwrites a file it cannot parse: a hand-edited config with a typo must not silently
/// reset the user's settings (spec §17, "preserve user configuration").
public final class ConfigStore {
    public private(set) var config: AppConfig
    public let url: URL
    /// Set when the last load found an existing but unreadable file.
    public private(set) var loadWarning: String?

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("PocketAgentRemote", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public init(url: URL? = nil) {
        self.url = url ?? Self.defaultURL()
        self.config = AppConfig()
    }

    @discardableResult
    public func load() -> AppConfig {
        loadWarning = nil
        guard FileManager.default.fileExists(atPath: url.path) else {
            // First run: write the defaults out so the file is there to be edited.
            try? save()
            return config
        }
        do {
            let data = try Data(contentsOf: url)
            config = try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            loadWarning = "could not read \(url.path) (\(error.localizedDescription)); using defaults and leaving the file untouched"
            config = AppConfig()
        }
        return config
    }

    public func save() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    public func update(_ mutate: (inout AppConfig) -> Void) {
        mutate(&config)
        try? save()
    }
}
