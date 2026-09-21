import Foundation

/// How the active tool profile is chosen.
///
/// The spec originally required the profile to be explicit and never inferred, because v0.1's plan
/// was to guess which agent was running *inside a terminal* — genuinely unreliable on macOS. Reading
/// the frontmost application's bundle ID is a different proposition: it is exact, and it is the same
/// signal the guard already uses. So automatic switching is offered, with the reasoning recorded
/// rather than the rule quietly dropped.
public enum ProfileMode: String, Codable, CaseIterable, Sendable {
    /// The user picks the profile in the menu; the frontmost app is only checked against the allowlist.
    case manual
    /// The frontmost app picks the profile. Unknown apps fall back to `fallbackProfile`.
    case auto
}

/// Persisted settings (spec §16).
public struct AppConfig: Codable, Equatable, Sendable {
    public var version: Int
    public var activeProfile: ToolProfile

    /// How `activeProfile` is chosen at any given moment.
    public var profileMode: ProfileMode
    /// Which profile each frontmost bundle ID selects, used in `.auto` mode.
    public var autoProfileBundleIDs: [String: String]
    /// Profile used in `.auto` mode when the frontmost app is not in `autoProfileBundleIDs`.
    public var fallbackProfile: ToolProfile

    /// The two desktop apps "focus the other agent" toggles between.
    ///
    /// This is its own pair rather than a reuse of `autoProfileBundleIDs` because the two answer
    /// different questions: that map says *which keymap* an app gets, this says *which two apps the
    /// remote is a remote for*. `left` is the first position and `right` the second, so a future
    /// explicit "left/right" switch reads straight off the same data instead of from a second list.
    public var agentPair: AgentPair

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

    /// Per-profile gesture overrides: `profile raw value` → `gesture identifier` → binding.
    ///
    /// Needed because the two tools have disjoint shortcut sets: `⌥⌘1` jumps to a chat in Codex and
    /// does nothing in Claude, whose equivalents are `⌘⇧[` / `⌘⇧]`. A profile-specific entry wins
    /// over the global `gestureKeyOverrides`.
    public var profileGestureKeyOverrides: [String: [String: KeyBinding]]

    /// The two agents the "switch agent" gesture toggles between.
    ///
    /// Both fields are optional so a partially written config still decodes — a missing side falls
    /// back to the built-in default for that side (see `AgentPair.resolved`).
    public struct AgentPair: Codable, Equatable, Sendable {
        /// First position — Codex by default.
        public var leftBundleID: String?
        /// Second position — Claude by default.
        public var rightBundleID: String?
        /// Optional display label for the left app; cosmetic (menu title, logs).
        public var leftName: String?
        /// Optional display label for the right app; cosmetic (menu title, logs).
        public var rightName: String?

        public init(
            leftBundleID: String? = nil,
            rightBundleID: String? = nil,
            leftName: String? = nil,
            rightName: String? = nil
        ) {
            self.leftBundleID = leftBundleID
            self.rightBundleID = rightBundleID
            self.leftName = leftName
            self.rightName = rightName
        }

        private enum CodingKeys: String, CodingKey {
            case leftBundleID, rightBundleID, leftName, rightName
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            leftBundleID = try container.decodeIfPresent(String.self, forKey: .leftBundleID)
            rightBundleID = try container.decodeIfPresent(String.self, forKey: .rightBundleID)
            leftName = try container.decodeIfPresent(String.self, forKey: .leftName)
            rightName = try container.decodeIfPresent(String.self, forKey: .rightName)
        }

        public static let `default` = AgentPair(
            leftBundleID: "com.openai.codex",
            rightBundleID: "com.anthropic.claudefordesktop",
            leftName: "Codex",
            rightName: "Claude"
        )

        /// The pair with each side filled in from the default when the config omitted it.
        public var resolved: AgentPair {
            AgentPair(
                leftBundleID: leftBundleID ?? Self.default.leftBundleID,
                rightBundleID: rightBundleID ?? Self.default.rightBundleID,
                leftName: leftName ?? Self.default.leftName,
                rightName: rightName ?? Self.default.rightName
            )
        }

        /// Both sides, left first, empty entries dropped.
        public var bundleIDs: [String] {
            [resolved.leftBundleID, resolved.rightBundleID].compactMap { id in
                guard let id, !id.isEmpty else { return nil }
                return id
            }
        }

        /// The label to show for a bundle ID, when one was configured.
        public func name(for bundleID: String) -> String? {
            let pair = resolved
            if bundleID == pair.leftBundleID { return pair.leftName }
            if bundleID == pair.rightBundleID { return pair.rightName }
            return nil
        }

        /// The side `frontmostBundleID` should switch to: the opposite agent while the user is in
        /// one of them, otherwise the left side.
        ///
        /// Reads the filtered `ids` rather than `resolved.left/right` directly, because a blank side
        /// is a legitimate way to configure a one-agent pair: the raw field can be `""`, and handing
        /// that to the activator would try to focus a bundle ID that cannot exist. With one agent,
        /// both branches answer that same agent — never nothing, never an empty string.
        public func target(from frontmostBundleID: String?) -> String? {
            let ids = bundleIDs
            guard let other = ids.first(where: { $0 != frontmostBundleID }) else {
                return ids.first
            }
            return other
        }
    }

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
        profileMode: ProfileMode = .auto,
        autoProfileBundleIDs: [String: String] = AppConfig.defaultAutoProfileBundleIDs,
        fallbackProfile: ToolProfile = .genericTerminal,
        agentPair: AgentPair = .default,
        tapMaxMs: Double = 220,
        holdMs: Double = 450,
        macrosEnabled: Bool = false,
        requireAllowedFrontmostApp: Bool = true,
        allowedBundleIDs: [String] = AppConfig.defaultAllowedBundleIDs,
        actionKeyOverrides: [String: KeyBinding] = [:],
        gestureKeyOverrides: [String: KeyBinding] = [:],
        profileGestureKeyOverrides: [String: [String: KeyBinding]] = [:]
    ) {
        self.version = version
        self.activeProfile = activeProfile
        self.profileMode = profileMode
        self.autoProfileBundleIDs = autoProfileBundleIDs
        self.fallbackProfile = fallbackProfile
        self.agentPair = agentPair
        self.tapMaxMs = tapMaxMs
        self.holdMs = holdMs
        self.macrosEnabled = macrosEnabled
        self.requireAllowedFrontmostApp = requireAllowedFrontmostApp
        self.allowedBundleIDs = allowedBundleIDs
        self.actionKeyOverrides = actionKeyOverrides
        self.gestureKeyOverrides = gestureKeyOverrides
        self.profileGestureKeyOverrides = profileGestureKeyOverrides
    }

    private enum CodingKeys: String, CodingKey {
        case version, activeProfile, profileMode, autoProfileBundleIDs, fallbackProfile, agentPair
        case tapMaxMs, holdMs
        case macrosEnabled, requireAllowedFrontmostApp, allowedBundleIDs
        case actionKeyOverrides, gestureKeyOverrides, profileGestureKeyOverrides
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
        profileMode = try container.decodeIfPresent(ProfileMode.self, forKey: .profileMode) ?? defaults.profileMode
        autoProfileBundleIDs = try container.decodeIfPresent([String: String].self, forKey: .autoProfileBundleIDs)
            ?? defaults.autoProfileBundleIDs
        fallbackProfile = try container.decodeIfPresent(ToolProfile.self, forKey: .fallbackProfile)
            ?? defaults.fallbackProfile
        agentPair = try container.decodeIfPresent(AgentPair.self, forKey: .agentPair)
            ?? defaults.agentPair
        tapMaxMs = try container.decodeIfPresent(Double.self, forKey: .tapMaxMs) ?? defaults.tapMaxMs
        holdMs = try container.decodeIfPresent(Double.self, forKey: .holdMs) ?? defaults.holdMs
        macrosEnabled = try container.decodeIfPresent(Bool.self, forKey: .macrosEnabled) ?? defaults.macrosEnabled
        requireAllowedFrontmostApp = try container.decodeIfPresent(Bool.self, forKey: .requireAllowedFrontmostApp)
            ?? defaults.requireAllowedFrontmostApp
        allowedBundleIDs = try container.decodeIfPresent([String].self, forKey: .allowedBundleIDs)
            ?? defaults.allowedBundleIDs
        actionKeyOverrides = try container.decodeIfPresent([String: KeyBinding].self, forKey: .actionKeyOverrides) ?? [:]
        gestureKeyOverrides = try container.decodeIfPresent([String: KeyBinding].self, forKey: .gestureKeyOverrides) ?? [:]
        profileGestureKeyOverrides = try container.decodeIfPresent(
            [String: [String: KeyBinding]].self,
            forKey: .profileGestureKeyOverrides
        ) ?? [:]
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

    /// Which profile each app selects in `.auto` mode.
    public static let defaultAutoProfileBundleIDs = [
        "com.openai.codex": ToolProfile.codex.rawValue,
        "com.anthropic.claudefordesktop": ToolProfile.claudeCode.rawValue,
    ]

    /// The profile in force right now.
    ///
    /// In `.manual` mode this is just `activeProfile`. In `.auto` mode it follows the frontmost
    /// application, falling back to `fallbackProfile` for anything unrecognised — which is what
    /// makes the allowlist redundant there: an unknown app can only ever get the generic profile,
    /// whose actions are arrows, Enter and Escape.
    public func resolvedProfile(frontmostBundleID: String?) -> ToolProfile {
        switch profileMode {
        case .manual:
            return activeProfile
        case .auto:
            guard let bundleID = frontmostBundleID,
                  let raw = autoProfileBundleIDs[bundleID],
                  let profile = ToolProfile(rawValue: raw)
            else { return fallbackProfile }
            return profile
        }
    }

    /// The guard policy in force right now.
    ///
    /// Auto mode drops the frontmost-app check rather than duplicating it: the profile was *derived*
    /// from the frontmost app, so a tool-specific action can only fire when its own app is in front.
    public var effectiveGuardPolicy: GuardPolicy {
        switch profileMode {
        case .manual:
            return guardPolicy
        case .auto:
            return GuardPolicy(
                allowedBundleIDs: [],
                requireAllowedFrontmostApp: false,
                macrosEnabled: macrosEnabled
            )
        }
    }

    public var gestureConfiguration: GestureConfiguration {
        GestureConfiguration(tapMaxMs: tapMaxMs, holdMs: holdMs)
    }

    /// Which app `focusOtherAgent` should put in front, given what is in front right now.
    ///
    /// While the user is in one of the two agents this answers "the other one", so a single gesture
    /// toggles in both directions. From anywhere else — a browser, a terminal, an unknown app — the
    /// answer is the left side, which keeps the gesture predictable instead of dependent on which
    /// agent happened to be used last.
    ///
    /// Nil means the pair is effectively empty (both sides removed from config), which the
    /// dispatcher reports rather than silently doing nothing.
    public func focusOtherAgentTarget(frontmostBundleID: String?) -> String? {
        agentPair.target(from: frontmostBundleID)
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
        resolvedGestureOverrides(profile: nil)
    }

    /// The overrides in force for a profile: global entries first, then that profile's own entries
    /// on top.
    public func gestureOverrides(for profile: ToolProfile) -> [String: GestureOverride] {
        resolvedGestureOverrides(profile: profile)
    }

    /// Bindings that ship enabled without appearing in the config file.
    ///
    /// Config wins over these (see `resolvedGestureOverrides`), so they are a default rather than a
    /// policy — and they exist so a new gesture does not require every existing config to be edited
    /// before it works.
    ///
    /// `a.hold` is push-to-talk on one button: hold A to talk, release to stop. It replaced the
    /// two-button `B+A` grab as the recommended trigger, and it fires under **any** frontmost app
    /// because it carries no command into one (same reasoning as a modifier-only chord).
    public static let defaultGestureOverrides: [String: KeyBinding] = [
        "a.hold": KeyBinding(modifiers: [.rightOption], hold: true),
    ]

    private func resolvedGestureOverrides(profile: ToolProfile?) -> [String: GestureOverride] {
        let known = Set(GestureID.all)
        var result: [String: GestureOverride] = [:]
        for (gesture, binding) in AppConfig.defaultGestureOverrides where known.contains(gesture) {
            result[gesture] = binding.gestureOverride
        }
        for (gesture, binding) in gestureKeyOverrides where known.contains(gesture) {
            result[gesture] = binding.gestureOverride
        }
        if let profile, let specific = profileGestureKeyOverrides[profile.rawValue] {
            for (gesture, binding) in specific where known.contains(gesture) {
                result[gesture] = binding.gestureOverride
            }
        }
        return result
    }

    /// Gesture identifiers the config used that we do not recognise — surfaced by the menu so a
    /// typo is visible instead of silently ignored.
    public var unknownGestureIDs: [String] {
        unknownGestureIDs(for: nil)
    }

    public func unknownGestureIDs(for profile: ToolProfile?) -> [String] {
        let known = Set(GestureID.all)
        var unknown = Set(gestureKeyOverrides.keys.filter { !known.contains($0) })
        if let profile, let specific = profileGestureKeyOverrides[profile.rawValue] {
            unknown.formUnion(specific.keys.filter { !known.contains($0) })
        }
        return unknown.sorted()
    }

    /// Profile names that are not real profiles — same reasoning as unknown gesture ids.
    public var unknownProfileNames: [String] {
        let known = Set(ToolProfile.allCases.map(\.rawValue))
        return profileGestureKeyOverrides.keys.filter { !known.contains($0) }.sorted()
    }
}

/// One-time adjustments to a config written for an older gesture map.
///
/// Not a general migration system — just the one place where a default binding changed underneath a
/// user who had *overridden* it, which is the case a tolerant decoder cannot help with: their
/// override still wins, so the old behaviour would silently survive the upgrade. `B+←` moved from
/// "new chat" to "open the menu" (2026-09-16), and anyone who had customised that chord per profile
/// would keep firing their old command and never see a menu.
public enum ConfigMigrations {
    /// Removes a per-profile `b.left` override **only when it still matches the old default it
    /// replaced** (`⌘N`).
    ///
    /// Matching the old value rather than removing the key outright is the conservative choice: an
    /// override the user set to something else is a deliberate choice and is left alone.
    ///
    /// Returns true when something was changed, so the caller can report it and back the file up.
    @discardableResult
    public static func adoptMenuChord(_ config: inout AppConfig) -> Bool {
        var changed = false
        for (profile, bindings) in config.profileGestureKeyOverrides {
            guard let binding = bindings["b.left"] else { continue }
            // The old Claude-side override was "⌘N with no hold" — the shape a raw keystroke takes.
            guard binding.key == .n, Set(binding.modifiers) == [.command], !binding.hold else { continue }
            config.profileGestureKeyOverrides[profile]?.removeValue(forKey: "b.left")
            if config.profileGestureKeyOverrides[profile]?.isEmpty ?? false {
                config.profileGestureKeyOverrides.removeValue(forKey: profile)
            }
            changed = true
        }
        return changed
    }

    /// Removes a `b.a` override **only when it is still the old push-to-talk default** (hold right
    /// ⌥, no key) — global or per profile.
    ///
    /// `B+A` became backspace on 2026-09-21; voice moved to holding A on its own (`a.hold`) five days
    /// earlier and every config that shipped in between carries this exact `b.a` entry, which would
    /// otherwise keep winning over the new default. Anything else the user put on `b.a` is theirs.
    @discardableResult
    public static func adoptBackspaceChord(_ config: inout AppConfig) -> Bool {
        func isOldVoiceGrab(_ binding: AppConfig.KeyBinding) -> Bool {
            binding.key == nil && Set(binding.modifiers) == [.rightOption] && binding.hold
        }
        var changed = false
        if let binding = config.gestureKeyOverrides["b.a"], isOldVoiceGrab(binding) {
            config.gestureKeyOverrides.removeValue(forKey: "b.a")
            changed = true
        }
        for (profile, bindings) in config.profileGestureKeyOverrides {
            guard let binding = bindings["b.a"], isOldVoiceGrab(binding) else { continue }
            config.profileGestureKeyOverrides[profile]?.removeValue(forKey: "b.a")
            if config.profileGestureKeyOverrides[profile]?.isEmpty ?? false {
                config.profileGestureKeyOverrides.removeValue(forKey: profile)
            }
            changed = true
        }
        return changed
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
    /// True while `config` holds defaults because the on-disk file could not be parsed. Any save is
    /// refused in that state — see `update`.
    public private(set) var didFailToLoad = false

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
        didFailToLoad = false
        guard FileManager.default.fileExists(atPath: url.path) else {
            // First run: write the defaults out so the file is there to be edited.
            try? save()
            return config
        }
        do {
            let data = try Data(contentsOf: url)
            config = try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            // The file exists but we could not understand it. Falling back to defaults is fine for
            // *this session*, but the file must not be rewritten from those defaults: a single typo
            // would otherwise silently destroy the user's real settings the next time a menu toggle
            // saves. `didFailToLoad` closes that door (see `update`).
            didFailToLoad = true
            loadWarning = "could not read \(url.path) (\(error.localizedDescription)); using defaults for this session and leaving the file untouched"
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

    /// Copies the current file aside before it is rewritten, and returns where it went.
    ///
    /// Used for the one automatic change to a user's config (see `ConfigMigrations`): a silent
    /// rewrite of hand-written settings is not acceptable, so the previous bytes are always kept.
    @discardableResult
    public func backUp() -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).backup-\(stamp)")
        do {
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }

    /// Applies a change and persists it.
    ///
    /// Refuses to write when the last `load()` could not parse the file (see `didFailToLoad`), and
    /// reports that instead of silently overwriting: the menu can carry on with the defaults it is
    /// showing, while the user's bytes stay on disk to be fixed by hand.
    @discardableResult
    public func update(_ mutate: (inout AppConfig) -> Void) -> SaveOutcome {
        mutate(&config)
        guard !didFailToLoad else {
            return .refusedUnreadableConfig
        }
        do {
            try save()
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// What happened to a config save. Returned rather than swallowed so a caller can tell the user.
public enum SaveOutcome: Equatable, Sendable {
    case saved
    /// The on-disk config exists but could not be parsed; writing would destroy it.
    case refusedUnreadableConfig
    case failed(String)

    public var didWrite: Bool { self == .saved }

    public var message: String? {
        switch self {
        case .saved:
            return nil
        case .refusedUnreadableConfig:
            return "config was NOT saved: the existing file could not be parsed, so it was left alone"
        case .failed(let reason):
            return "config could NOT be saved: \(reason)"
        }
    }
}
