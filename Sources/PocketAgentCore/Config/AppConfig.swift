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

    /// Per-gesture keystroke overrides, keyed by gesture identifier (see `GestureID`).
    ///
    /// This goes further than `actionKeyOverrides`: it lets a gesture send a key that has no
    /// semantic action at all, e.g. pointing `b.a` at `⇧⎋` (Clear all unreads). The semantic
    /// vocabulary stays small while the reachable command set becomes the whole Codex shortcut list.
    public var gestureKeyOverrides: [String: KeyBinding]

    public struct KeyBinding: Codable, Equatable, Sendable {
        /// Nil means **modifiers only**, e.g. `{ "modifiers": ["option", "shift"] }` — no character
        /// key is pressed.
        public var key: Key?
        public var modifiers: [ModifierKey]
        /// Hold the stroke for the whole chord instead of tapping it. Only meaningful for
        /// modifier-only strokes (see `GestureOverride.isHeld`).
        public var hold: Bool

        public init(key: Key? = nil, modifiers: [ModifierKey] = [], hold: Bool = false) {
            self.key = key
            self.modifiers = modifiers
            self.hold = hold
        }

        private enum CodingKeys: String, CodingKey {
            case key, modifiers, hold
        }

        /// Every field is optional on purpose: `{ "key": "b" }` (unmodified key) and
        /// `{ "modifiers": ["option", "shift"] }` (modifiers only) are both natural to write, and
        /// neither must fail the decode of the whole config.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            key = try container.decodeIfPresent(Key.self, forKey: .key)
            modifiers = try container.decodeIfPresent([ModifierKey].self, forKey: .modifiers) ?? []
            hold = try container.decodeIfPresent(Bool.self, forKey: .hold) ?? false
        }

        public var stroke: KeyStroke {
            KeyStroke(key: key, modifiers: Set(modifiers))
        }

        public var gestureOverride: GestureOverride {
            GestureOverride(stroke: stroke, isHeld: hold)
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
        actionKeyOverrides: [String: KeyBinding] = [:],
        gestureKeyOverrides: [String: KeyBinding] = [:]
    ) {
        self.version = version
        self.activeProfile = activeProfile
        self.tapMaxMs = tapMaxMs
        self.holdMs = holdMs
        self.macrosEnabled = macrosEnabled
        self.requireAllowedFrontmostApp = requireAllowedFrontmostApp
        self.allowedBundleIDs = allowedBundleIDs
        self.actionKeyOverrides = actionKeyOverrides
        self.gestureKeyOverrides = gestureKeyOverrides
    }

    private enum CodingKeys: String, CodingKey {
        case version, activeProfile, tapMaxMs, holdMs
        case macrosEnabled, requireAllowedFrontmostApp, allowedBundleIDs
        case actionKeyOverrides, gestureKeyOverrides
    }

    /// Tolerant decoding: **every** field falls back to its default when absent.
    ///
    /// The synthesised decoder would reject any config written by an older build the moment a new
    /// field is added — which, given this file is meant to be hand-edited, would mean silently
    /// resetting the user's settings on upgrade. Missing keys must not be an error.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? defaults.version
        activeProfile = try container.decodeIfPresent(ToolProfile.self, forKey: .activeProfile) ?? defaults.activeProfile
        tapMaxMs = try container.decodeIfPresent(Double.self, forKey: .tapMaxMs) ?? defaults.tapMaxMs
        holdMs = try container.decodeIfPresent(Double.self, forKey: .holdMs) ?? defaults.holdMs
        macrosEnabled = try container.decodeIfPresent(Bool.self, forKey: .macrosEnabled) ?? defaults.macrosEnabled
        requireAllowedFrontmostApp = try container.decodeIfPresent(Bool.self, forKey: .requireAllowedFrontmostApp)
            ?? defaults.requireAllowedFrontmostApp
        allowedBundleIDs = try container.decodeIfPresent([String].self, forKey: .allowedBundleIDs)
            ?? defaults.allowedBundleIDs
        actionKeyOverrides = try container.decodeIfPresent([String: KeyBinding].self, forKey: .actionKeyOverrides) ?? [:]
        gestureKeyOverrides = try container.decodeIfPresent([String: KeyBinding].self, forKey: .gestureKeyOverrides) ?? [:]
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

    /// Gesture overrides with unknown identifiers dropped, so a typo degrades to "that one gesture
    /// keeps its default" rather than silently doing nothing.
    public var gestureOverrides: [String: GestureOverride] {
        var result: [String: GestureOverride] = [:]
        let known = Set(GestureID.all)
        for (gesture, binding) in gestureKeyOverrides where known.contains(gesture) {
            result[gesture] = binding.gestureOverride
        }
        return result
    }

    /// Gesture identifiers the config used that we do not recognise — surfaced by the menu so a
    /// typo is visible instead of silently ignored.
    public var unknownGestureIDs: [String] {
        let known = Set(GestureID.all)
        return gestureKeyOverrides.keys.filter { !known.contains($0) }.sorted()
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
